#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>
#include "PythonRunner.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct lilc_python_job {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    atomic_bool stopped;
    int eof;
    int finishing;
    double deadline;
    int timed_out;
    char *input;
    size_t output_bytes;
    lilc_python_output output;
    lilc_python_wait waiting;
    void *context;
};
static pthread_mutex_t engine_lock = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local lilc_python_job *active_job;
static int initialized;

lilc_python_job *lilc_python_create(void) {
    lilc_python_job *j = calloc(1, sizeof(*j));
    if (!j) return NULL;
    pthread_mutex_init(&j->lock, NULL); pthread_cond_init(&j->condition, NULL);
    atomic_init(&j->stopped, 0);
    return j;
}
void lilc_python_destroy(lilc_python_job *j) {
    if (!j) return;
    free(j->input); pthread_mutex_destroy(&j->lock); pthread_cond_destroy(&j->condition); free(j);
}
void lilc_python_stop(lilc_python_job *j) {
    atomic_store(&j->stopped, 1);
    pthread_mutex_lock(&j->lock); pthread_cond_broadcast(&j->condition); pthread_mutex_unlock(&j->lock);
}
void lilc_python_eof(lilc_python_job *j) {
    pthread_mutex_lock(&j->lock); j->eof = 1; pthread_cond_broadcast(&j->condition); pthread_mutex_unlock(&j->lock);
}
void lilc_python_input(lilc_python_job *j, const char *line) {
    pthread_mutex_lock(&j->lock);
    size_t old = j->input ? strlen(j->input) : 0, extra = strlen(line);
    char *next = realloc(j->input, old + extra + 1);
    if (next) { j->input = next; memcpy(next + old, line, extra + 1); }
    pthread_cond_broadcast(&j->condition); pthread_mutex_unlock(&j->lock);
}
static double monotonic_seconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}
static int check_stop(void) {
    lilc_python_job *j = active_job;
    if (j && !j->finishing && atomic_load(&j->stopped)) { PyErr_SetString(PyExc_KeyboardInterrupt, "Stopped"); return -1; }
    if (j && !j->finishing && j->deadline > 0 && monotonic_seconds() >= j->deadline) {
        j->timed_out = 1;
        // BaseException avoids broad Exception handlers in symbolic algorithms swallowing the deadline.
        PyErr_SetString(PyExc_KeyboardInterrupt, "Calculation time limit reached."); return -1;
    }
    return 0;
}
static int trace(PyObject *obj, PyFrameObject *frame, int what, PyObject *arg) {
    (void)obj; (void)frame; (void)what; (void)arg;
    return check_stop();
}
static PyObject *emit(PyObject *self, PyObject *args) {
    (void)self;
    const char *s; Py_ssize_t length;
    if (!PyArg_ParseTuple(args, "s#", &s, &length)) return NULL;
    lilc_python_job *j = active_job;
    if (check_stop() < 0) return NULL;
    if (j->output_bytes + length > 1024 * 1024) { PyErr_SetString(PyExc_RuntimeError, "Console output limit reached (1 MB)."); return NULL; }
    j->output_bytes += length;
    j->output(s, (int)length, j->context);
    return PyLong_FromSsize_t(length);
}
static PyObject *read_line(PyObject *self, PyObject *args) {
    (void)self; (void)args;
    lilc_python_job *j = active_job;
    char *line = NULL;
    j->waiting(1, j->context);
    Py_BEGIN_ALLOW_THREADS
    pthread_mutex_lock(&j->lock);
    while (!j->input && !j->eof && !atomic_load(&j->stopped)) pthread_cond_wait(&j->condition, &j->lock);
    if (j->input) {
        char *end = strchr(j->input, '\n');
        size_t count = end ? (size_t)(end - j->input + 1) : strlen(j->input);
        line = strndup(j->input, count);
        char *rest = j->input[count] ? strdup(j->input + count) : NULL;
        free(j->input); j->input = rest;
    }
    pthread_mutex_unlock(&j->lock);
    Py_END_ALLOW_THREADS
    j->waiting(0, j->context);
    if (check_stop() < 0) { free(line); return NULL; }
    PyObject *result = PyUnicode_DecodeUTF8(line ? line : "", line ? strlen(line) : 0, "replace");
    free(line); return result;
}
static PyObject *sleep_interruptible(PyObject *self, PyObject *args) {
    (void)self;
    double seconds;
    if (!PyArg_ParseTuple(args, "d", &seconds)) return NULL;
    if (seconds < 0) { PyErr_SetString(PyExc_ValueError, "sleep length must be non-negative"); return NULL; }
    while (seconds > 0) {
        if (check_stop() < 0) return NULL;
        double step = seconds > 0.05 ? 0.05 : seconds;
        struct timespec delay = {0, (long)(step * 1e9)};
        Py_BEGIN_ALLOW_THREADS
        nanosleep(&delay, NULL);
        Py_END_ALLOW_THREADS
        seconds -= step;
    }
    Py_RETURN_NONE;
}
static PyObject *enable_trace(PyObject *, PyObject *);
static PyMethodDef methods[] = {
    {"enable_trace", enable_trace, METH_NOARGS, NULL},
    {"write", emit, METH_VARARGS, NULL}, {"readline", read_line, METH_NOARGS, NULL},
    {"sleep", sleep_interruptible, METH_VARARGS, NULL}, {NULL, NULL, 0, NULL}
};
int lilc_python_run(lilc_python_job *j, const char *home, const char *bootstrap, const char *path, const char *root,
                    lilc_python_output output, lilc_python_wait waiting, void *context) {
    pthread_mutex_lock(&engine_lock);
    if (atomic_load(&j->stopped)) { pthread_mutex_unlock(&engine_lock); return 2; }
    j->output = output; j->waiting = waiting; j->context = context; active_job = j;
    if (!initialized) {
        PyConfig config; PyConfig_InitIsolatedConfig(&config);
        config.write_bytecode = 0; config.buffered_stdio = 0; config.install_signal_handlers = 0;
        PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
        if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            const char *error = status.err_msg ? status.err_msg : "Could not initialize Python";
            output(error, (int)strlen(error), context); active_job = NULL;
            pthread_mutex_unlock(&engine_lock); return 1;
        }
        initialized = 1; PyEval_SaveThread();
    }
    char *previous_directory = getcwd(NULL, 0);
    PyGILState_STATE gil = PyGILState_Ensure();
    PyThreadState *main_state = PyThreadState_Get();
    PyThreadState *state = Py_NewInterpreter();
    int failed = 1;
    if (state) {
        PyObject *module = PyModule_New("_lilc");
        PyModule_AddFunctions(module, methods);
        PyDict_SetItemString(PyImport_GetModuleDict(), "_lilc", module);
        Py_DECREF(module);
        PyObject *globals = PyDict_New();
        PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
        PyObject *p = PyUnicode_DecodeFSDefault(path), *r = PyUnicode_DecodeFSDefault(root);
        PyDict_SetItemString(globals, "_script_path", p); PyDict_SetItemString(globals, "_project_root", r);
        Py_DECREF(p); Py_DECREF(r);
        FILE *file = fopen(bootstrap, "r");
        if (file) {
            PyObject *result = PyRun_FileEx(file, bootstrap, Py_file_input, globals, globals, 1);
            if (result) {
                PyObject *failure = PyDict_GetItemString(globals, "_failed");
                failed = !failure || PyObject_IsTrue(failure) != 0; Py_DECREF(result);
            }
            else PyErr_Print();
        }
        j->finishing = 1;
        PyDict_SetItemString(globals, "_finishing", Py_True);
        PyEval_SetTrace(NULL, NULL);
        Py_DECREF(globals); Py_EndInterpreter(state); PyThreadState_Swap(main_state);
    }
    PyGILState_Release(gil);
    if (previous_directory) { chdir(previous_directory); free(previous_directory); }
    active_job = NULL; pthread_mutex_unlock(&engine_lock);
    return atomic_load(&j->stopped) ? 2 : failed;
}
// Trace activation is exported only to the internal bootstrap module.
static PyObject *enable_trace(PyObject *self, PyObject *args) {
    (void)self; (void)args; PyEval_SetTrace(trace, NULL); Py_RETURN_NONE;
}

// Kept warm between requests, isolated from each disposable IDE interpreter.
static PyThreadState *math_state;
static PyObject *math_globals;
int lilc_python_calculate(lilc_python_job *j, const char *home, const char *bootstrap, const char *packages,
                          const char *request, double seconds, lilc_python_output output, void *context) {
    if (!j || !home || !bootstrap || !packages || !request || !output || seconds <= 0) return 1;
    if (pthread_mutex_trylock(&engine_lock) != 0) return 3;
    if (atomic_load(&j->stopped)) { pthread_mutex_unlock(&engine_lock); return 2; }
    if (!initialized) {
        PyConfig config; PyConfig_InitIsolatedConfig(&config);
        config.write_bytecode = 0; config.buffered_stdio = 0; config.install_signal_handlers = 0;
        PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
        if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) { pthread_mutex_unlock(&engine_lock); return 1; }
        initialized = 1; PyEval_SaveThread();
    }
    PyGILState_STATE gil = PyGILState_Ensure();
    PyThreadState *main_state = PyThreadState_Get();
    active_job = j;
    // Importing SymPy must not consume the calculation budget on a cold device.
    j->deadline = monotonic_seconds() + 30.0;
    int startup_timed_out = 0;
    int failed = 1;
    if (!math_state) {
        math_state = Py_NewInterpreter();
        if (math_state) {
            math_globals = PyDict_New();
            PyDict_SetItemString(math_globals, "__builtins__", PyEval_GetBuiltins());
            PyObject *path = PyUnicode_DecodeFSDefault(packages);
            PyDict_SetItemString(math_globals, "_math_packages", path); Py_DECREF(path);
            PyEval_SetTrace(trace, NULL);
            FILE *file = fopen(bootstrap, "r");
            PyObject *loaded = file ? PyRun_FileEx(file, bootstrap, Py_file_input, math_globals, math_globals, 1) : NULL;
            if (!loaded) {
                startup_timed_out = j->timed_out;
                PyErr_Clear(); PyEval_SetTrace(NULL, NULL);
                Py_DECREF(math_globals); math_globals = NULL;
                Py_EndInterpreter(math_state); math_state = NULL;
                PyThreadState_Swap(main_state);
            } else { Py_DECREF(loaded); }
        }
    } else { PyThreadState_Swap(math_state); }
    if (math_state) {
        j->deadline = monotonic_seconds() + seconds;
        PyEval_SetTrace(trace, NULL);
        PyObject *function = PyDict_GetItemString(math_globals, "_calculate_json");
        PyObject *arg = PyUnicode_FromString(request);
        PyObject *result = function ? PyObject_CallOneArg(function, arg) : NULL;
        Py_DECREF(arg);
        if (result) {
            Py_ssize_t size;
            const char *value = PyUnicode_AsUTF8AndSize(result, &size);
            if (value && size <= 16384 && check_stop() == 0 && !j->timed_out) {
                output(value, (int)size, context); failed = 0;
            }
            Py_DECREF(result);
        }
        PyErr_Clear(); PyEval_SetTrace(NULL, NULL);
        if (j->timed_out || atomic_load(&j->stopped)) {
            // Do not reuse potentially interrupted imports or symbolic caches.
            Py_DECREF(math_globals); math_globals = NULL;
            Py_EndInterpreter(math_state); math_state = NULL;
        }
        PyThreadState_Swap(main_state);
    }
    PyThreadState_Swap(main_state);
    active_job = NULL;
    PyGILState_Release(gil);
    pthread_mutex_unlock(&engine_lock);
    return atomic_load(&j->stopped) ? 2 : (startup_timed_out ? 5 : (j->timed_out ? 4 : failed));
}
