// Regression harness for the production C bridge using a host CPython build.
#include "PythonRunner.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *home, *packages, *math_bootstrap, *ide_bootstrap, *script, *root;
static const char *request = "{\"operation\":\"evaluate\",\"expression\":\"1/3+1/6\"}";
static char captured[16385];
static atomic_int waiting;
static void output(const char *bytes, int count, void *ctx) {
    (void)ctx;
    assert(count >= 0 && count <= 16384);
    memcpy(captured, bytes, (size_t)count); captured[count] = 0;
}
static void discard(const char *bytes, int count, void *ctx) { (void)bytes; (void)count; (void)ctx; }
static void wait_changed(int active, void *ctx) { (void)ctx; atomic_store(&waiting, active); }
static int calculate(lilc_python_job *job, double seconds) {
    return lilc_python_calculate(job, home, math_bootstrap, packages, request, seconds, output, NULL);
}
static void success(void) {
    lilc_python_job *job = lilc_python_create(); assert(job);
    captured[0] = 0;
    int status = calculate(job, 8);
    if (status != 0) fprintf(stderr, "math status=%d output=%s\n", status, captured);
    assert(status == 0); assert(strstr(captured, "\"exact\": \"1/2\""));
    lilc_python_destroy(job);
}
static void integral_work(void) {
    const char *simple = "{\"operation\":\"integrate\",\"expression\":\"x^2\",\"lower\":\"0\",\"upper\":\"1\"}";
    lilc_python_job *simple_job = lilc_python_create(); assert(simple_job);
    captured[0] = 0;
    assert(lilc_python_calculate(simple_job, home, math_bootstrap, packages, simple, 8, output, NULL) == 0);
    assert(strstr(captured, "\"exact\": \"1/3\""));
    lilc_python_destroy(simple_job);
    const char *worked = "{\"operation\":\"integrate\",\"expression\":\"x^2*ln(1+x)\",\"lower\":\"0\",\"upper\":\"1\",\"include_work\":true}";
    lilc_python_job *job = lilc_python_create(); assert(job);
    captured[0] = 0;
    assert(lilc_python_calculate(job, home, math_bootstrap, packages, worked, 8, output, NULL) == 0);
    assert(strstr(captured, "\"steps\":"));
    assert(strstr(captured, "-5/18 + 2*log(2)/3"));
    assert(strstr(captured, "Rewrite the integrand"));
    lilc_python_destroy(job);
    job = lilc_python_create();
    assert(lilc_python_calculate(job, home, math_bootstrap, packages, worked, 0.000000001, output, NULL) == 4);
    lilc_python_destroy(job);
    success(); // optional work deadline does not poison the next calculation
}
static void *ide(void *arg) {
    int status = lilc_python_run(arg, home, ide_bootstrap, script, root, discard, wait_changed, NULL);
    assert(status == 0); return NULL;
}
static void *math_on_worker(void *arg) { (void)arg; success(); return NULL; }
static void *cancel_cold_math(void *arg) {
    int status = calculate(arg, 8); assert(status == 2); return NULL;
}
static void ide_round_trip(void) {
    pthread_t worker;
    atomic_store(&waiting, 0);
    lilc_python_job *ide_job = lilc_python_create(); assert(ide_job);
    pthread_create(&worker, NULL, ide, ide_job);
    for (int i = 0; i < 5000 && !atomic_load(&waiting); i++) usleep(1000);
    assert(atomic_load(&waiting));
    lilc_python_job *job = lilc_python_create(); assert(job);
    assert(calculate(job, 8) == 3); lilc_python_destroy(job);
    lilc_python_input(ide_job, "done\n"); pthread_join(worker, NULL); lilc_python_destroy(ide_job);
}
int main(int argc, char **argv) {
    assert(argc == 8 || argc == 9);
    home = argv[1]; packages = argv[2]; math_bootstrap = argv[3]; ide_bootstrap = argv[4]; script = argv[5]; root = argv[6];
    if (argc == 9) ide_round_trip();
    // Slow startup exceeds the execution budget but must not time out the calculation.
    const char *production_bootstrap = math_bootstrap;
    math_bootstrap = argv[7];
    lilc_python_job *startup_job = lilc_python_create();
    assert(calculate(startup_job, 0.05) == 0);
    lilc_python_destroy(startup_job);
    startup_job = lilc_python_create();
    assert(calculate(startup_job, 0.000000001) == 4);
    lilc_python_destroy(startup_job);
    math_bootstrap = production_bootstrap;
    success(); success(); // cold and warm interpreter
    integral_work();
    pthread_t worker;
    pthread_create(&worker, NULL, math_on_worker, NULL); pthread_join(worker, NULL);
    lilc_python_job *job = lilc_python_create(); assert(job);
    assert(calculate(job, 0.000000001) == 4); lilc_python_destroy(job);
    success(); // clean recovery after a discarded timed-out interpreter
    job = lilc_python_create(); lilc_python_stop(job); assert(calculate(job, 8) == 2); lilc_python_destroy(job);
    job = lilc_python_create(); assert(calculate(job, 0.000000001) == 4); lilc_python_destroy(job);
    job = lilc_python_create();
    pthread_create(&worker, NULL, cancel_cold_math, job);
    usleep(2000); lilc_python_stop(job); pthread_join(worker, NULL); lilc_python_destroy(job);
    success();
    ide_round_trip();
    success();
    puts("Native bridge checks passed: cold/warm, cross-thread, deadline, cancellation, IDE isolation/busy, recovery.");
    return 0;
}
