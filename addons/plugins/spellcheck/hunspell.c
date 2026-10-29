// Lua binding for hunspell, as a lite-xl native module (require "plugins.spellcheck.hunspell").
// Based on luahunspell.cpp (Matt White, 2010), using hunspell's C API.
//
//   local h = hunspell.new("/usr/share/hunspell/en_US.aff", "/usr/share/hunspell/en_US.dic")
//   h:spell("teh")      --> false
//   h:suggest("teh")    --> { "the", "tea", ... }
//   h:add("lite")       -- accepted from now on (this instance only, not saved)

#include <stdio.h>
#include <string.h>
#include <hunspell.h>
#ifdef _WIN32
  #include <windows.h>
#endif

#define LITE_XL_PLUGIN_ENTRYPOINT
#include <lite_xl_plugin_api.h>

#define HUNSPELL_MT "hunspell"

typedef struct { Hunhandle* h; } hunspell_t;

// Whether a file can be read. Pushes the path as hunspell takes it: on Windows an
// absolute one gets the long path prefix (\\?\, backslashes only), with which hunspell
// opens it as UTF-8, as the editor's paths are, rather than in the ANSI code page.
static int push_path(lua_State* L, const char* path) {
#ifdef _WIN32
  int absolute = ((path[0] && path[1] == ':') || (path[0] == '\\' && path[1] == '\\'))
    && strncmp(path, "\\\\?\\", 4) != 0;
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  if (absolute)
    luaL_addstring(&b, path[1] == ':' ? "\\\\?\\" : "\\\\?\\UNC");
  for (const char* c = absolute && path[1] != ':' ? path + 1 : path; *c; ++c)
    luaL_addchar(&b, absolute && *c == '/' ? '\\' : *c);
  luaL_pushresult(&b);
  wchar_t wide[4096];
  if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, sizeof(wide) / sizeof(wide[0])))
    return 0;
  FILE* fp = _wfopen(wide, L"r");
#else
  lua_pushstring(L, path);
  FILE* fp = fopen(path, "r");
#endif
  if (fp) fclose(fp);
  return fp != NULL;
}

static Hunhandle* check(lua_State* L) {
  hunspell_t* self = luaL_checkudata(L, 1, HUNSPELL_MT);
  if (!self->h) luaL_error(L, "hunspell instance is closed");
  return self->h;
}

// hunspell.new(aff_path, dic_path): nil, error when a file can't be read
// (hunspell itself accepts missing files and then rejects every word)
static int f_new(lua_State* L) {
  const char* aff = luaL_checkstring(L, 1);
  const char* dic = luaL_checkstring(L, 2);
  const char* paths[] = { aff, dic };
  for (int i = 0; i < 2; i++) {
    if (!push_path(L, paths[i])) {
      lua_pushnil(L);
      lua_pushfstring(L, "cannot read %s", paths[i]);
      return 2;
    }
  }
  hunspell_t* self = lua_newuserdata(L, sizeof(hunspell_t));
  self->h = Hunspell_create(lua_tostring(L, -3), lua_tostring(L, -2));
  luaL_setmetatable(L, HUNSPELL_MT);
  return 1;
}

static int f_spell(lua_State* L) {
  Hunhandle* h = check(L);
  lua_pushboolean(L, Hunspell_spell(h, luaL_checkstring(L, 2)) != 0);
  return 1;
}

static int f_suggest(lua_State* L) {
  Hunhandle* h = check(L);
  char** list;
  int n = Hunspell_suggest(h, &list, luaL_checkstring(L, 2));
  lua_createtable(L, n, 0);
  for (int i = 0; i < n; i++) {
    lua_pushstring(L, list[i]);
    lua_rawseti(L, -2, i + 1);
  }
  Hunspell_free_list(h, &list, n);
  return 1;
}

static int f_add(lua_State* L) {
  Hunhandle* h = check(L);
  lua_pushboolean(L, Hunspell_add(h, luaL_checkstring(L, 2)) == 0);
  return 1;
}

static int f_gc(lua_State* L) {
  hunspell_t* self = luaL_checkudata(L, 1, HUNSPELL_MT);
  if (self->h) Hunspell_destroy(self->h);
  self->h = NULL;
  return 0;
}

static const luaL_Reg methods[] = {
  { "spell", f_spell },
  { "suggest", f_suggest },
  { "add", f_add },
  { "close", f_gc },
  { "__gc", f_gc },
  { NULL, NULL }
};

int luaopen_lite_xl_hunspell(lua_State* L, void* XL) {
  lite_xl_plugin_init(XL);
  luaL_newmetatable(L, HUNSPELL_MT);
  luaL_setfuncs(L, methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  lua_newtable(L);
  lua_pushcfunction(L, f_new);
  lua_setfield(L, -2, "new");
  return 1;
}
