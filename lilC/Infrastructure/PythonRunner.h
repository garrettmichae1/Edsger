#pragma once
#include <stdint.h>
typedef struct lilc_python_job lilc_python_job;
typedef void (*lilc_python_output)(const char *, int, void *);
typedef void (*lilc_python_wait)(int, void *);
lilc_python_job *lilc_python_create(void);
void lilc_python_destroy(lilc_python_job *job);
void lilc_python_stop(lilc_python_job *job);
void lilc_python_input(lilc_python_job *job, const char *line);
void lilc_python_eof(lilc_python_job *job);
int lilc_python_run(lilc_python_job *job, const char *home, const char *bootstrap, const char *path, const char *root, lilc_python_output output, lilc_python_wait waiting, void *context);
// Startup has a separate 30-second budget; seconds applies only to calculation.
// Dedicated trusted math interpreter. 0=JSON result, 1=engine failure, 2=cancelled,
// 3=engine busy, 4=calculation deadline, 5=startup deadline. Deadlines/cancellation are cooperative.
int lilc_python_calculate(lilc_python_job *job, const char *home, const char *bootstrap, const char *packages,
                          const char *request, double seconds, lilc_python_output output, void *context);
