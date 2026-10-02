#pragma once
#include <stdint.h>
typedef struct lilc_lua_job lilc_lua_job;
typedef void (*lilc_lua_output)(const char *, int, void *);
typedef void (*lilc_lua_wait)(int, void *);
lilc_lua_job *lilc_lua_create(void);
void lilc_lua_destroy(lilc_lua_job *job);
void lilc_lua_stop(lilc_lua_job *job);
void lilc_lua_input(lilc_lua_job *job, const char *line);
void lilc_lua_eof(lilc_lua_job *job);
int lilc_lua_run(lilc_lua_job *job, const char *bootstrap, const char *path, const char *root, lilc_lua_output output, lilc_lua_wait waiting, void *context);
