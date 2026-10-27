# Applies resources/windows/001-lua-unicode.diff to a Lua 5.4.4 source tree without
# needing patch(1) or git: adds the wrapper sources and the luaconf.h hook.
# Usage: cmake -DLUA_DIR=<lua source dir> -DUTF8_DIR=<cmake/lua-utf8> -P PatchLuaUtf8.cmake
# Safe to run more than once.

set(luaconf "${LUA_DIR}/src/luaconf.h")
file(READ "${luaconf}" content)
if(NOT content MATCHES "utf8_wrappers\\.h")
  string(REGEX REPLACE "#endif[ \t\r\n]*$" "" content "${content}")
  string(APPEND content
"#if defined(lua_c) || defined(luac_c) || (defined(LUA_LIB) && \\
    (defined(lauxlib_c) || defined(liolib_c) || \\
     defined(loadlib_c) || defined(loslib_c)))
#include \"utf8_wrappers.h\"
#endif

#endif
")
  file(WRITE "${luaconf}" "${content}")
endif()
file(COPY "${UTF8_DIR}/utf8_wrappers.c" "${UTF8_DIR}/utf8_wrappers.h"
     DESTINATION "${LUA_DIR}/src")
