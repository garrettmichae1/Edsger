#define PY_SSIZE_T_CLEAN
#if __APPLE__
#include <Python/Python.h>
#else
#include <Python.h>
#endif
#include "PythonRunner.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <limits.h>
#include <fcntl.h>
#include <sys/statvfs.h>
#include <sys/stat.h>

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
    char *project_root;
    char *python_root;
    char *framework_root;
    int sandbox_active;
};
static pthread_mutex_t engine_lock = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local lilc_python_job *active_job;
static int initialized;
static int audit_installed;
static _Thread_local int changing_native_trace;
static void set_native_trace(Py_tracefunc function) {
    changing_native_trace = 1;
    PyEval_SetTrace(function, NULL);
    changing_native_trace = 0;
}
static PyInterpreterState *sandbox_interpreter;
static lilc_python_job *sandbox_job;

static int deny_operation(void) {
    PyErr_SetString(PyExc_PermissionError, "This operation is unavailable in the project runtime.");
    return -1;
}
static int inside_root(const char *path, const char *root) {
    size_t length = strlen(root);
    return strncmp(path, root, length) == 0 && (path[length] == '\0' || path[length] == '/');
}
// Resolve existing paths and the nearest existing ancestor of a new file.
// The policy roots live in native memory, never in script-visible globals.
static int allowed_path(PyObject *value, int writing) {
    if (!PyUnicode_Check(value) && !PyBytes_Check(value)) return deny_operation();
    PyObject *encoded = NULL;
    if (!PyUnicode_FSConverter(value, &encoded)) return -1;
    const char *raw = PyBytes_AS_STRING(encoded);
    if ((Py_ssize_t)strlen(raw) != PyBytes_GET_SIZE(encoded) || strlen(raw) >= PATH_MAX) {
        Py_DECREF(encoded); return deny_operation();
    }
    char candidate[PATH_MAX], resolved[PATH_MAX];
    if (raw[0] == '/') snprintf(candidate, sizeof(candidate), "%s", raw);
    else if (snprintf(candidate, sizeof(candidate), "%s/%s", sandbox_job->project_root, raw) >= PATH_MAX) {
        Py_DECREF(encoded); return deny_operation();
    }
    Py_DECREF(encoded);
    // Reject parent traversal even for not-yet-created paths. realpath covers links.
    for (const char *p = candidate; *p; p++) {
        if ((p == candidate || p[-1] == '/') && p[0] == '.' && p[1] == '.' && (p[2] == '/' || p[2] == '\0')) return deny_operation();
    }
    while (!realpath(candidate, resolved)) {
        struct stat info;
        // A dangling link is an existing path entry. Removing it from the
        // candidate would authorize its parent while open follows another target.
        if (lstat(candidate, &info) == 0 && S_ISLNK(info.st_mode)) return deny_operation();
        char *slash = strrchr(candidate, '/');
        if (!slash || slash == candidate) return deny_operation();
        *slash = '\0';
    }
    int bundled_extension = 0;
    if (!writing && sandbox_job->framework_root && inside_root(resolved, sandbox_job->framework_root)) {
        const char *relative = resolved + strlen(sandbox_job->framework_root);
        bundled_extension = strncmp(relative, "/PythonModule-", 14) == 0;
    }
    if (!inside_root(resolved, sandbox_job->project_root) && (writing || (!inside_root(resolved, sandbox_job->python_root) && !bundled_extension))) return deny_operation();
    if (writing) {
        struct statvfs space;
        if (statvfs(sandbox_job->project_root, &space) != 0 || space.f_bavail * space.f_frsize < 1024 * 1024) {
            PyErr_SetString(PyExc_OSError, "Not enough free space to write project files."); return -1;
        }
    }
    return 0;
}
static int project_audit(const char *event, PyObject *args, void *unused) {
    (void)unused;
    if (!sandbox_job || !sandbox_job->sandbox_active || PyThreadState_GetInterpreter(PyThreadState_Get()) != sandbox_interpreter) return 0;
    if (strncmp(event, "ctypes.", 7) == 0 || strncmp(event, "socket.", 7) == 0 || strncmp(event, "subprocess.", 11) == 0 ||
        strncmp(event, "os.exec", 7) == 0 || strncmp(event, "os.spawn", 8) == 0 || strncmp(event, "os.fork", 7) == 0 ||
        strncmp(event, "fcntl.", 6) == 0 || strncmp(event, "mmap.", 5) == 0 || strncmp(event, "_thread.", 8) == 0 ||
        (strcmp(event, "sys.settrace") == 0 && !changing_native_trace) || strcmp(event, "sys.setprofile") == 0 || strcmp(event, "sys.addaudithook") == 0 ||
        strcmp(event, "os.system") == 0 || strcmp(event, "os.chdir") == 0 || strcmp(event, "os.fchdir") == 0 ||
        strcmp(event, "os.kill") == 0 || strcmp(event, "os.killpg") == 0 || strcmp(event, "os.posix_spawn") == 0 ||
        strcmp(event, "os.putenv") == 0 || strcmp(event, "os.unsetenv") == 0) return deny_operation();
    if (strcmp(event, "import") == 0) {
        const char *name = PyUnicode_AsUTF8(PyTuple_GetItem(args, 0));
        if (!name) return -1;
        static const char *blocked[] = {"ctypes", "_ctypes", "subprocess", "_posixsubprocess", "multiprocessing", "threading", "_thread", "socket", "_socket", "signal", "resource", "mmap", "fcntl", "_testcapi", "_testinternalcapi", NULL};
        for (int i = 0; blocked[i]; i++) {
            size_t n = strlen(blocked[i]);
            for (const char *part = name; part; part = strchr(part, '.') ? strchr(part, '.') + 1 : NULL) {
                if (strncmp(part, blocked[i], n) == 0 && (part[n] == '\0' || part[n] == '.')) {
                    // Standard-library modules catch ImportError to select safe
                    // fallbacks (e.g. pathlib's optional fcntl in Python 3.14).
                    PyErr_SetString(PyExc_ImportError, "This module is unavailable in the project runtime."); return -1;
                }
            }
        }
        PyObject *filename = PyTuple_GetItem(args, 1);
        if (filename && filename != Py_None && allowed_path(filename, 0) < 0) return -1;
    }
    if (strcmp(event, "open") == 0) {
        PyObject *flags = PyTuple_GetItem(args, 2);
        long mode = PyLong_Check(flags) ? PyLong_AsLong(flags) : 0;
        if (PyErr_Occurred()) return -1;
        return allowed_path(PyTuple_GetItem(args, 0), (mode & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND)) != 0);
    }
    if (strcmp(event, "os.listdir") == 0 || strcmp(event, "os.scandir") == 0) {
        PyObject *path = PyTuple_GetItem(args, 0);
        if (path != Py_None) return allowed_path(path, 0);
        PyObject *current = PyUnicode_FromString(".");
        if (!current) return -1;
        int result = allowed_path(current, 0); Py_DECREF(current); return result;
    }
    if (strcmp(event, "os.link") == 0 || strcmp(event, "os.symlink") == 0) return deny_operation();
    if (strcmp(event, "os.remove") == 0 || strcmp(event, "os.rmdir") == 0 || strcmp(event, "os.mkdir") == 0 ||
        strcmp(event, "os.rename") == 0 || strcmp(event, "os.chmod") == 0 || strcmp(event, "os.chown") == 0 ||
        strcmp(event, "os.truncate") == 0 || strcmp(event, "os.utime") == 0) {
        int paths = strcmp(event, "os.rename") == 0 ? 2 : 1;
        for (int i = 0; i < paths; i++) if (allowed_path(PyTuple_GetItem(args, i), 1) < 0) return -1;
        // dir_fd changes the meaning of a relative path; never authorize it using cwd.
        int first_fd = strcmp(event, "os.rename") == 0 ? 2 : strcmp(event, "os.chmod") == 0 || strcmp(event, "os.chown") == 0 || strcmp(event, "os.mkdir") == 0 ? 2 : strcmp(event, "os.utime") == 0 ? 3 : 1;
        for (Py_ssize_t i = first_fd; i < PyTuple_GET_SIZE(args); i++) {
            PyObject *fd = PyTuple_GET_ITEM(args, i);
            if (PyLong_Check(fd) && PyLong_AsLong(fd) != -1) return deny_operation();
        }
    }
    if (strcmp(event, "sqlite3.connect") == 0) {
        PyObject *name = PyTuple_GetItem(args, 0);
        const char *text = PyUnicode_Check(name) ? PyUnicode_AsUTF8(name) : NULL;
        if (text && strcmp(text, ":memory:") == 0) return 0;
        if (!text || strncmp(text, "file:", 5) == 0) return deny_operation();
        return allowed_path(name, 1);
    }
    return 0;
}
static int install_project_audit(void) {
    if (audit_installed) return 0;
    if (PySys_AddAuditHook(project_audit, NULL) != 0) return -1;
    audit_installed = 1;
    return 0;
}

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
        if (install_project_audit() != 0) { active_job = NULL; pthread_mutex_unlock(&engine_lock); return 1; }
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
        j->project_root = realpath(root, NULL); j->python_root = realpath(home, NULL);
#if __APPLE__
        char framework_path[PATH_MAX];
        if (snprintf(framework_path, sizeof(framework_path), "%s/../Frameworks", home) < PATH_MAX) j->framework_root = realpath(framework_path, NULL);
#endif
        if (!j->project_root || !j->python_root) {
            free(j->project_root); free(j->python_root); free(j->framework_root); j->project_root = j->python_root = j->framework_root = NULL;
            Py_EndInterpreter(state); PyThreadState_Swap(main_state);
            PyGILState_Release(gil); active_job = NULL; pthread_mutex_unlock(&engine_lock); return 1;
        }
        sandbox_job = j; sandbox_interpreter = PyThreadState_GetInterpreter(state);
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
        set_native_trace(NULL);
        Py_DECREF(globals); Py_EndInterpreter(state); PyThreadState_Swap(main_state);
        sandbox_interpreter = NULL; sandbox_job = NULL;
        free(j->project_root); free(j->python_root); free(j->framework_root); j->project_root = j->python_root = j->framework_root = NULL;
    }
    PyGILState_Release(gil);
    if (previous_directory) { chdir(previous_directory); free(previous_directory); }
    active_job = NULL; pthread_mutex_unlock(&engine_lock);
    return atomic_load(&j->stopped) ? 2 : failed;
}
// Trace activation is exported only to the internal bootstrap module.
static PyObject *enable_trace(PyObject *self, PyObject *args) {
    (void)self; (void)args;
    if (active_job) active_job->sandbox_active = 1;
    set_native_trace(trace); Py_RETURN_NONE;
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
        if (install_project_audit() != 0) { pthread_mutex_unlock(&engine_lock); return 1; }
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
            set_native_trace(trace);
            FILE *file = fopen(bootstrap, "r");
            PyObject *loaded = file ? PyRun_FileEx(file, bootstrap, Py_file_input, math_globals, math_globals, 1) : NULL;
            if (!loaded) {
                startup_timed_out = j->timed_out;
                PyErr_Clear(); set_native_trace(NULL);
                Py_DECREF(math_globals); math_globals = NULL;
                Py_EndInterpreter(math_state); math_state = NULL;
                PyThreadState_Swap(main_state);
            } else { Py_DECREF(loaded); }
        }
    } else { PyThreadState_Swap(math_state); }
    if (math_state) {
        j->deadline = monotonic_seconds() + seconds;
        set_native_trace(trace);
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
        PyErr_Clear(); set_native_trace(NULL);
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
