#include "LuaRunner.h"
#include "../Vendor/Lua/lua.h"
#include "../Vendor/Lua/lualib.h"
#include "../Vendor/Lua/lauxlib.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
struct lilc_lua_job {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    atomic_bool stopped;
    int eof;
    size_t memory;
    const char *root;
    char *input;
    size_t output_bytes;
    lilc_lua_output output;
    lilc_lua_wait waiting;
    void *context;
};




lilc_lua_job *lilc_lua_create(void) {
    lilc_lua_job *j = calloc(1, sizeof(*j));
    if (!j) return NULL;
    pthread_mutex_init(&j->lock, NULL); pthread_cond_init(&j->condition, NULL);
    atomic_init(&j->stopped, 0);
    return j;
}
void lilc_lua_destroy(lilc_lua_job *j) {
    if (!j) return;
    free(j->input); pthread_mutex_destroy(&j->lock); pthread_cond_destroy(&j->condition); free(j);
}
void lilc_lua_stop(lilc_lua_job *j) {
    atomic_store(&j->stopped, 1);
    pthread_mutex_lock(&j->lock); pthread_cond_broadcast(&j->condition); pthread_mutex_unlock(&j->lock);
}
void lilc_lua_eof(lilc_lua_job *j) {
    pthread_mutex_lock(&j->lock); j->eof = 1; pthread_cond_broadcast(&j->condition); pthread_mutex_unlock(&j->lock);
}
void lilc_lua_input(lilc_lua_job *j, const char *line) {
    pthread_mutex_lock(&j->lock);
    size_t old = j->input ? strlen(j->input) : 0, extra = strlen(line);
    char *next = realloc(j->input, old + extra + 1);
    if (next) { j->input = next; memcpy(next + old, line, extra + 1); }
    pthread_cond_broadcast(&j->condition); pthread_mutex_unlock(&j->lock);
}
static lilc_lua_job *job(lua_State *L) { return *(lilc_lua_job **)lua_getextraspace(L); }
static void hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (atomic_load(&job(L)->stopped)) luaL_error(L, "Stopped.");
}
static void *allocate(void *context, void *ptr, size_t old, size_t size) {
    lilc_lua_job *j = context;
    if (!ptr) old = 0;
    if (!size) { free(ptr); j->memory -= old; return NULL; }
    if (size > old && size - old > 64 * 1024 * 1024 - j->memory) return NULL;
    void *next = realloc(ptr, size);
    if (next) j->memory = j->memory - old + size;
    return next;
}
static int write_text(lua_State *L) {
    lilc_lua_job *j = job(L); size_t length;
    const char *text = luaL_checklstring(L, 1, &length);
    if (atomic_load(&j->stopped)) return luaL_error(L, "Stopped.");
    if (j->output_bytes + length > 1024 * 1024) return luaL_error(L, "Console output limit reached (1 MB).");
    j->output_bytes += length; j->output(text, (int)length, j->context); return 0;
}
static int read_text(lua_State *L) {
    lilc_lua_job *j = job(L); char *line = NULL;
    j->waiting(1, j->context);
    pthread_mutex_lock(&j->lock);
    while (!j->input && !j->eof && !atomic_load(&j->stopped)) pthread_cond_wait(&j->condition, &j->lock);
    if (j->input) {
        char *end = strchr(j->input, '\n'); size_t count = end ? end - j->input + 1 : strlen(j->input);
        line = strndup(j->input, count);
        char *rest = j->input[count] ? strdup(j->input + count) : NULL;
        free(j->input); j->input = rest;
    }
    pthread_mutex_unlock(&j->lock); j->waiting(0, j->context);
    if (atomic_load(&j->stopped)) { free(line); return luaL_error(L, "Stopped."); }
    if (line) { lua_pushstring(L, line); free(line); } else lua_pushnil(L);
    return 1;
}
static int safe_path(lua_State *L) {
    const char *relative = luaL_checkstring(L, 1), *root = job(L)->root;
    char joined[PATH_MAX], resolved[PATH_MAX], parent[PATH_MAX];
    if (relative[0] == '/' || strchr(relative, '\n') || strlen(relative) != lua_rawlen(L,1)) return luaL_error(L, "Use a project-relative path.");
    if (snprintf(joined, sizeof(joined), "%s/%s", root, relative) >= sizeof(joined)) return luaL_error(L, "Path too long.");
    if (!realpath(joined, resolved)) {
        strcpy(parent, joined); char *slash = strrchr(parent,'/'); *slash = 0;
        if (!realpath(parent, resolved)) return luaL_error(L,"Parent folder does not exist.");
        size_t length = strlen(resolved);
        if (length + strlen(slash+1) + 2 >= sizeof(resolved)) return luaL_error(L,"Path too long.");
        strcat(resolved,"/"); strcat(resolved,slash+1);
    }
    size_t length = strlen(root);
    if (strncmp(resolved, root, length) || resolved[length] != '/' || strstr(resolved,"/../") || !strcmp(resolved+length,"/..")) return luaL_error(L,"Files must stay inside this project.");
    lua_pushstring(L, resolved); return 1;
}
static int load_text_file(lua_State *L) {
    safe_path(L);
    const char *path = lua_tostring(L,-1);
    if (luaL_loadfilex(L,path,"t") != LUA_OK) return lua_error(L);
    return 1;
}
static int traceback(lua_State *L) {
    const char *message = lua_tostring(L,1);
    if (message) luaL_traceback(L,L,message,1); else lua_pushliteral(L,"Lua error");
    return 1;
}
int lilc_lua_run(lilc_lua_job *j, const char *bootstrap, const char *path, const char *root, lilc_lua_output output, lilc_lua_wait waiting, void *context) {
    if (atomic_load(&j->stopped)) return 2;
    char canonical[PATH_MAX]; if (!realpath(root, canonical)) return 1;
    j->root=canonical; j->output=output; j->waiting=waiting; j->context=context;
    lua_State *L=lua_newstate(allocate,j,0); if (!L) return 1;
    *(lilc_lua_job **)lua_getextraspace(L)=j;
    // Only these libraries are opened; OS commands, native package loading, and debug are absent.
    const luaL_Reg libraries[]={{LUA_GNAME,luaopen_base},{LUA_TABLIBNAME,luaopen_table},{LUA_STRLIBNAME,luaopen_string},{LUA_MATHLIBNAME,luaopen_math},{LUA_UTF8LIBNAME,luaopen_utf8},{LUA_COLIBNAME,luaopen_coroutine},{LUA_IOLIBNAME,luaopen_io},{LUA_OSLIBNAME,luaopen_os},{NULL,NULL}};
    for (const luaL_Reg *lib=libraries; lib->func; lib++) { luaL_requiref(L,lib->name,lib->func,1); lua_pop(L,1); }
    lua_pushcfunction(L,write_text); lua_setglobal(L,"_lilc_write");
    lua_pushcfunction(L,read_text); lua_setglobal(L,"_lilc_read");
    lua_pushcfunction(L,safe_path); lua_setglobal(L,"_lilc_path");
    lua_pushcfunction(L,load_text_file); lua_setglobal(L,"_lilc_load");
    lua_sethook(L,hook,LUA_MASKCOUNT,1000);
    lua_pushcfunction(L,traceback); int handler=lua_gettop(L);
    int status=luaL_loadfilex(L,bootstrap,"t");
    if (status==LUA_OK) status=lua_pcall(L,0,0,handler);
    if (status==LUA_OK) {
        lua_createtable(L,1,0); lua_pushstring(L,path); lua_rawseti(L,-2,0); lua_setglobal(L,"arg");
        status=luaL_loadfilex(L,path,"t");
        if (status==LUA_OK) status=lua_pcall(L,0,0,handler);
    }
    if (status!=LUA_OK && !atomic_load(&j->stopped)) {
        size_t length; const char *message=lua_tolstring(L,-1,&length);
        if (message) output(message,(int)length,context);
    }
    lua_close(L);
    return atomic_load(&j->stopped) ? 2 : status!=LUA_OK;
}
