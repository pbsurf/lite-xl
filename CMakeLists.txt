# CMake build for Lite XL, the one scripts/run.sh uses; meson.build is upstream's (and CI's).
#
# All dependencies (Lua, PCRE2, FreeType, SDL3; hunspell for spellcheck) are downloaded as
# hash-pinned release tarballs with FetchContent and built statically in-tree, so the only
# tools needed are CMake (3.20+), a C and C++ compiler and, on Windows, nothing else: no
# Python, Git or pkg-config.  On Linux the system's SDL3, FreeType and PCRE2 are used
# instead by default (LITE_SYSTEM_SDL, LITE_SYSTEM_FREETYPE, LITE_SYSTEM_PCRE2), as the
# meson build does.
#
#   cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#   cmake --install build --prefix <dir>
#
# Offline: point FETCHCONTENT_SOURCE_DIR_<LUA|PCRE2|FREETYPE|SDL3|HUNSPELL> at unpacked sources.
# Not ported: the innosetup script, macOS bundles. lpm is built on Linux and macOS only.

cmake_minimum_required(VERSION 3.20)

if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)   # extracted archives get the time of extraction
endif()

# MSVC debug info (a PDB in every configuration) goes in the objects with /Z7, not
# /Zi: no shared compiler PDB, so parallel builds need no /FS or mspdbsrv
if(POLICY CMP0141)
  cmake_policy(SET CMP0141 NEW)
  set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT Embedded)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Windows" OR WIN32)
  set(_lite_langs C RC)
else()
  set(_lite_langs C)
endif()
project(lite-xl VERSION 2.1.8 LANGUAGES ${_lite_langs})

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_EXTENSIONS ON)   # gnu11
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(LITE_PORTABLE "Portable install layout (always on for Windows)" OFF)
option(LITE_USE_SDL_RENDERER "Use the SDL renderer (always on for macOS)" OFF)
# Linux: the distribution's libraries (shared) are maintained and patched for the system,
# SDL's for its desktops; elsewhere there are none to use. Off builds the pinned release
# statically (e.g. FreeType for perf to see its internals).
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(_system_default ON)
else()
  set(_system_default OFF)
endif()
option(LITE_SYSTEM_SDL "Link the system's SDL3 rather than building SDL 3.2 statically"
       ${_system_default})
option(LITE_SYSTEM_FREETYPE "Link the system's FreeType rather than building it" ${_system_default})
option(LITE_SYSTEM_PCRE2 "Link the system's PCRE2 rather than building it" ${_system_default})
set(LITE_DIRMONITOR_BACKEND "" CACHE STRING
    "dirmonitor backend: inotify, fsevents, kqueue, win32, dummy (default: detect)")
set(LITE_ARCH_TUPLE "" CACHE STRING "custom architecture tuple (default: <cpu>-<system>)")

#===============================================================================
# Project version, including the git commit for non-release builds
#===============================================================================
set(LITE_VERSION_STR "${PROJECT_VERSION}")
if(NOT CMAKE_BUILD_TYPE STREQUAL "Release")
  find_package(Git QUIET)
  if(GIT_FOUND)
    execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse HEAD
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      OUTPUT_VARIABLE _git_commit OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET RESULT_VARIABLE _git_rc)
    if(_git_rc EQUAL 0 AND _git_commit)
      string(SUBSTRING "${_git_commit}" 0 8 _git_short)
      set(LITE_VERSION_STR "${PROJECT_VERSION} (git-${_git_short})")
    endif()
  endif()
endif()

# names the configured templates (start.lua, the manifest) use
set(PROJECT_VERSION "${LITE_VERSION_STR}")
set(PROJECT_ASSEMBLY_VERSION "${CMAKE_PROJECT_VERSION}.0")

#===============================================================================
# Architecture tuple, <cpu family>-<system> as in meson
#===============================================================================
if(LITE_ARCH_TUPLE)
  set(arch_tuple "${LITE_ARCH_TUPLE}")
else()
  string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _cpu)
  if(_cpu MATCHES "^(amd64|x86_64|x64)$")
    set(_cpu x86_64)
  elseif(_cpu MATCHES "^(arm64|aarch64)$")
    set(_cpu aarch64)
  elseif(_cpu MATCHES "^(i[3-6]86|x86)$")
    set(_cpu x86)
  endif()
  string(TOLOWER "${CMAKE_SYSTEM_NAME}" _sys)
  set(arch_tuple "${_cpu}-${_sys}")
endif()

#===============================================================================
# Dependencies
#===============================================================================
include(FetchContent)

if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.28)
  set(_exclude EXCLUDE_FROM_ALL)   # keep the dependencies' install rules out of ours
else()
  set(_exclude "")
endif()

# built statically and without install rules; set around the dependencies only
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_SKIP_INSTALL_RULES ON)

# ---- Lua 5.4: has no CMake build, so only fetched; built below ------------------
set(_lua_patch "")
if(WIN32)   # UTF-8 file names, see resources/windows/001-lua-unicode.diff
  set(_lua_patch PATCH_COMMAND "${CMAKE_COMMAND}" -DLUA_DIR=<SOURCE_DIR>
      -DUTF8_DIR=${CMAKE_CURRENT_SOURCE_DIR}/cmake/lua-utf8
      -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/PatchLuaUtf8.cmake)
endif()
FetchContent_Declare(lua
  URL https://www.lua.org/ftp/lua-5.4.4.tar.gz
  URL_HASH SHA256=164c7849653b80ae67bec4b7473b884bf5cc8d2dca05653475ec2ed27b9ebf61
  ${_lua_patch}
  SOURCE_SUBDIR no-cmake-build)   # nonexistent: populate only, no add_subdirectory
FetchContent_MakeAvailable(lua)

set(lua_sources)
foreach(f lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes
          lparser lstate lstring ltable ltm lundump lvm lzio lauxlib lbaselib lcorolib
          ldblib liolib lmathlib loadlib loslib lstrlib ltablib lutf8lib linit)
  list(APPEND lua_sources "${lua_SOURCE_DIR}/src/${f}.c")
endforeach()
if(WIN32)
  list(APPEND lua_sources "${lua_SOURCE_DIR}/src/utf8_wrappers.c")
endif()
add_library(lite_lua STATIC ${lua_sources})
target_include_directories(lite_lua PUBLIC "${lua_SOURCE_DIR}/src")
if(NOT WIN32)
  target_compile_definitions(lite_lua PRIVATE LUA_USE_POSIX LUA_USE_DLOPEN)
  target_link_libraries(lite_lua PUBLIC ${CMAKE_DL_LIBS} m)
endif()
if(MSVC)
  target_compile_definitions(lite_lua PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# the dependencies fetched and built here, as opposed to the system's
set(_fetched)

# ---- PCRE2: the system's (pkg-config), or static -----------------------------------------
if(LITE_SYSTEM_PCRE2)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(PCRE2 REQUIRED IMPORTED_TARGET libpcre2-8)
  set(lite_pcre2 PkgConfig::PCRE2)
  message(STATUS "PCRE2: the system's, ${PCRE2_VERSION}")
else()
  set(PCRE2_BUILD_PCRE2_8 ON CACHE BOOL "" FORCE)
  set(PCRE2_BUILD_PCRE2_16 OFF CACHE BOOL "" FORCE)
  set(PCRE2_BUILD_PCRE2_32 OFF CACHE BOOL "" FORCE)
  set(PCRE2_BUILD_PCRE2GREP OFF CACHE BOOL "" FORCE)
  set(PCRE2_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(PCRE2_SUPPORT_JIT ON CACHE BOOL "" FORCE)
  set(PCRE2_STATIC_RUNTIME OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(pcre2
    URL https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2
    URL_HASH SHA256=d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96
    ${_exclude})
  list(APPEND _fetched pcre2)
  set(lite_pcre2 pcre2-8-static)
endif()

# ---- FreeType: the system's, or static without its optional codecs ----------------------
if(LITE_SYSTEM_FREETYPE)
  find_package(Freetype REQUIRED)
  set(lite_freetype Freetype::Freetype)
  message(STATUS "FreeType: the system's, ${FREETYPE_VERSION_STRING}")
else()
  foreach(opt ZLIB BZIP2 PNG HARFBUZZ BROTLI)
    set(FT_DISABLE_${opt} ON CACHE BOOL "" FORCE)
  endforeach()
  set(SKIP_INSTALL_ALL ON CACHE BOOL "" FORCE)
  FetchContent_Declare(freetype
    URL https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
        https://downloads.sourceforge.net/project/freetype/freetype2/2.13.3/freetype-2.13.3.tar.xz
    URL_HASH SHA256=0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
    ${_exclude})
  list(APPEND _fetched freetype)
  set(lite_freetype freetype)
endif()

# ---- SDL3, static, with the features as upstream's scripts/build.sh, plus the file dialogs
# (system.open_file_dialog; Windows: comdlg32, Linux: the portal or zenity at runtime);
# not with LITE_SYSTEM_SDL -------------------------------------------------------------
if(NOT LITE_SYSTEM_SDL)
  set(SDL_STATIC ON CACHE BOOL "" FORCE)
  set(SDL_SHARED OFF CACHE BOOL "" FORCE)
  set(SDL_TESTS OFF CACHE BOOL "" FORCE)
  set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
  foreach(opt AUDIO CAMERA JOYSTICK HAPTIC HIDAPI SENSOR POWER GPU VULKAN)
    set(SDL_${opt} OFF CACHE BOOL "" FORCE)
  endforeach()
  set(SDL_DIALOG ON CACHE BOOL "" FORCE)
  set(SDL_VENDOR_INFO "lite-xl" CACHE STRING "" FORCE)
  if(UNIX AND NOT APPLE)
    set(SDL_RPATH OFF CACHE BOOL "" FORCE)
    set(SDL_PIPEWIRE OFF CACHE BOOL "" FORCE)
    set(SDL_LIBUDEV OFF CACHE BOOL "" FORCE)
    set(SDL_X11 ON CACHE BOOL "" FORCE)
    set(SDL_WAYLAND ON CACHE BOOL "" FORCE)
    set(SDL_DBUS ON CACHE BOOL "" FORCE)
    set(SDL_IBUS ON CACHE BOOL "" FORCE)
  endif()
  FetchContent_Declare(sdl3
    URL https://github.com/libsdl-org/SDL/releases/download/release-3.2.14/SDL3-3.2.14.tar.gz
    URL_HASH SHA256=b7e7dc05011b88c69170fe18935487b2559276955e49113f8c1b6b72c9b79c1f
    ${_exclude})
  list(APPEND _fetched sdl3)
  set(lite_sdl SDL3::SDL3-static)
else()
  find_package(SDL3 REQUIRED CONFIG COMPONENTS SDL3-shared)
  set(lite_sdl SDL3::SDL3-shared)
  message(STATUS "SDL3: the system's, ${SDL3_VERSION}")
endif()

if(_fetched)
  FetchContent_MakeAvailable(${_fetched})
endif()
set(CMAKE_SKIP_INSTALL_RULES OFF)

#===============================================================================
# Sources, with the dirmonitor backend chosen as meson does
#===============================================================================
set(lite_sources
  src/api/api.c
  src/api/renderer.c
  src/api/regex.c
  src/api/system.c
  src/api/process.c
  src/api/readwatch.c
  src/api/utf8.c
  src/arena_allocator.c
  src/renderer.c
  src/renwindow.c
  src/rencache.c
  src/main.c
  src/api/dirmonitor.c
)

include(CheckSymbolExists)
set(dirmonitor_backend "${LITE_DIRMONITOR_BACKEND}")
if(NOT dirmonitor_backend)
  check_symbol_exists(inotify_init sys/inotify.h HAVE_INOTIFY)
  check_symbol_exists(kqueue sys/event.h HAVE_KQUEUE)
  if(HAVE_INOTIFY)
    set(dirmonitor_backend inotify)
  elseif(APPLE)
    set(dirmonitor_backend fsevents)
  elseif(HAVE_KQUEUE)
    set(dirmonitor_backend kqueue)
  elseif(WIN32)
    set(dirmonitor_backend win32)
  else()
    message(WARNING "no suitable dirmonitor backend found, defaulting to dummy")
    set(dirmonitor_backend dummy)
  endif()
endif()
message(STATUS "dirmonitor_backend: ${dirmonitor_backend}")
list(APPEND lite_sources "src/api/dirmonitor/${dirmonitor_backend}.c")

if(APPLE)
  enable_language(OBJC)
  list(APPEND lite_sources src/bundle_open.m)
endif()

# Windows resources: icon and manifest in one generated .rc, with absolute paths
if(WIN32)
  configure_file(resources/windows/lite-xl.exe.manifest.in
                 "${CMAKE_CURRENT_BINARY_DIR}/lite-xl.exe.manifest" @ONLY)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/lite-xl.rc"
    "id ICON \"${CMAKE_CURRENT_SOURCE_DIR}/resources/icons/icon.ico\"\n"
    "1 24 \"${CMAKE_CURRENT_BINARY_DIR}/lite-xl.exe.manifest\"\n")
  list(APPEND lite_sources "${CMAKE_CURRENT_BINARY_DIR}/lite-xl.rc")
  set_source_files_properties("${CMAKE_CURRENT_BINARY_DIR}/lite-xl.rc"
    PROPERTIES OBJECT_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/lite-xl.exe.manifest")
endif()

#===============================================================================
# The executable
#===============================================================================
add_executable(lite-xl WIN32 ${lite_sources})
target_include_directories(lite-xl PRIVATE src)
if(NOT LITE_SYSTEM_PCRE2)
  target_include_directories(lite-xl PRIVATE "${pcre2_BINARY_DIR}")
  target_compile_definitions(lite-xl PRIVATE PCRE2_STATIC)
endif()
target_link_libraries(lite-xl PRIVATE lite_lua ${lite_pcre2} ${lite_freetype} ${lite_sdl})
target_compile_definitions(lite-xl PRIVATE
  "LITE_PROJECT_VERSION_STR=\"${LITE_VERSION_STR}\""
  "LITE_ARCH_TUPLE=\"${arch_tuple}\"")
if(LITE_USE_SDL_RENDERER OR APPLE)
  target_compile_definitions(lite-xl PRIVATE LITE_USE_SDL_RENDERER)
endif()
if(APPLE)
  target_link_libraries(lite-xl PRIVATE "-framework CoreServices" "-framework Foundation")
endif()
if(MSVC)
  if(NOT POLICY CMP0141)   # CMake < 3.25: no CMAKE_MSVC_DEBUG_INFORMATION_FORMAT
    foreach(_cfg RELEASE MINSIZEREL RELWITHDEBINFO DEBUG)
      string(REGEX REPLACE "/Z[7iI]" "" CMAKE_C_FLAGS_${_cfg} "${CMAKE_C_FLAGS_${_cfg}}")
      string(APPEND CMAKE_C_FLAGS_${_cfg} " /Z7")
    endforeach()
  endif()
  target_compile_definitions(lite-xl PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(lite-xl PRIVATE /utf-8)
  # /DEBUG writes lite-xl.pdb; it turns off the linker's dead-code removal, so ask again
  target_link_options(lite-xl PRIVATE /MANIFEST:NO   # ours is in the .rc
                      /DEBUG /OPT:REF /OPT:ICF)
endif()

#===============================================================================
# Start script, generated like meson's configure_file
#===============================================================================
configure_file(data/core/start.lua "${CMAKE_CURRENT_BINARY_DIR}/start.lua" @ONLY)

#===============================================================================
# Native parts of our add-ons, built into <build>/addons/plugins/<plugin> (not installed), so
# that <build>/addons is a directory of add-ons for core.add_addon_dir, with the module where
# package.cpath finds it as <module>.<arch_tuple>.<so|dll|lib> (InstallAddons.cmake copies it
# into the installed plugin instead, with COPY).  They don't link Lua: lite_xl_plugin_api.h finds it
# in the executable.
#===============================================================================
if(WIN32)
  set(module_ext dll)
elseif(APPLE)
  set(module_ext lib)
else()
  set(module_ext so)
endif()

add_library(libterminal MODULE addons/plugins/terminal/libterminal.c)
set_target_properties(libterminal PROPERTIES
  PREFIX ""
  OUTPUT_NAME libterminal
  SUFFIX ".${arch_tuple}.${module_ext}"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/addons/plugins/terminal"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/addons/plugins/terminal")
target_include_directories(libterminal PRIVATE resources/include)
if(MSVC)
  # the entry point isn't marked for export; Windows has no forkpty, the plugin uses ConPTY
  target_link_options(libterminal PRIVATE /EXPORT:luaopen_lite_xl_libterminal /DEBUG)
  target_compile_definitions(libterminal PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(libterminal PRIVATE /utf-8)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_libraries(libterminal PRIVATE util)
endif()

# spellcheck's hunspell module, with hunspell (C++) fetched and built statically into it.
# Dictionaries aren't part of it: InstallAddons.cmake downloads en_US into the user dir.
option(LITE_SPELLCHECK "Build the spellcheck plugin's hunspell module" ON)
if(LITE_SPELLCHECK)
  enable_language(CXX)
  FetchContent_Declare(hunspell
    URL https://github.com/hunspell/hunspell/releases/download/v1.7.2/hunspell-1.7.2.tar.gz
    URL_HASH SHA256=11ddfa39afe28c28539fe65fc4f1592d410c1e9b6dd7d8a91ca25d85e9ec65b8
    SOURCE_SUBDIR no-cmake-build)   # autotools only: populate, built below
  FetchContent_MakeAvailable(hunspell)
  set(hunspell_sources)
  foreach(f affentry affixmgr csutil filemgr hashmgr hunspell hunzip phonet replist suggestmgr)
    list(APPEND hunspell_sources "${hunspell_SOURCE_DIR}/src/hunspell/${f}.cxx")
  endforeach()
  add_library(lite_hunspell STATIC ${hunspell_sources})
  # (the release has hunvisapi.h made already, which HUNSPELL_STATIC makes export nothing)
  target_include_directories(lite_hunspell PUBLIC "${hunspell_SOURCE_DIR}/src/hunspell")
  target_compile_definitions(lite_hunspell PUBLIC HUNSPELL_STATIC)
  set_target_properties(lite_hunspell PROPERTIES CXX_STANDARD 11)
  if(MSVC)
    target_compile_definitions(lite_hunspell PRIVATE _CRT_SECURE_NO_WARNINGS)
    target_compile_options(lite_hunspell PRIVATE /utf-8 /EHsc /wd4267 /wd4244)
  endif()

  add_library(hunspell_module MODULE addons/plugins/spellcheck/hunspell.c)
  set_target_properties(hunspell_module PROPERTIES
    PREFIX ""
    OUTPUT_NAME hunspell
    SUFFIX ".${arch_tuple}.${module_ext}"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/addons/plugins/spellcheck"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/addons/plugins/spellcheck")
  target_include_directories(hunspell_module PRIVATE resources/include)
  target_link_libraries(hunspell_module PRIVATE lite_hunspell)
  if(MSVC)
    target_link_options(hunspell_module PRIVATE /EXPORT:luaopen_lite_xl_hunspell /DEBUG)
    target_compile_definitions(hunspell_module PRIVATE _CRT_SECURE_NO_WARNINGS)
    target_compile_options(hunspell_module PRIVATE /utf-8)
  endif()
endif()

#===============================================================================
# lpm, the plugin manager scripts/lpm runs, as in lpm/meson.build: built into <build>/lpm (not
# installed), against the system's libgit2, libzip, mbedtls, zlib and liblzma (pkg-config).
# It loads lpm/src/lpm.lua from the source tree when it starts, so edits to it need no
# rebuild. AUTO: skipped when a dependency is missing; not on Windows, which uses
# InstallAddons.cmake instead.
#===============================================================================
set(LITE_LPM AUTO CACHE STRING "Build lpm: ON, OFF or AUTO (when its dependencies are found)")
if(NOT WIN32 AND NOT LITE_LPM STREQUAL "OFF")
  find_package(PkgConfig)
  set(_lpm_required "")
  if(LITE_LPM STREQUAL "ON")
    set(_lpm_required REQUIRED)
  endif()
  if(PKG_CONFIG_FOUND)
    pkg_check_modules(LPM_DEPS ${_lpm_required} IMPORTED_TARGET
      zlib liblzma libgit2 libzip mbedtls mbedx509 mbedcrypto)
  elseif(LITE_LPM STREQUAL "ON")
    message(FATAL_ERROR "lpm needs pkg-config to find its dependencies")
  endif()
  if(LPM_DEPS_FOUND)
    find_package(Threads REQUIRED)
    add_executable(lpm lpm/src/lpm.c lpm/lib/microtar/src/microtar.c)
    set_target_properties(lpm PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/lpm")
    target_include_directories(lpm PRIVATE lpm/lib/microtar/src)
    target_link_libraries(lpm PRIVATE lite_lua PkgConfig::LPM_DEPS Threads::Threads)
    target_compile_definitions(lpm PRIVATE
      "LPM_LUA_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/lpm/src/lpm.lua\""
      "LPM_VERSION=\"1.4.9\""
      "LPM_DEFAULT_RELEASE=\"\"")
  else()
    message(STATUS "lpm: not built (its dependencies weren't found)")
  endif()
endif()

# Run in place from the build directory: build/data next to the executable (and its PDB)
add_custom_command(TARGET lite-xl POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -DSRC=${CMAKE_CURRENT_SOURCE_DIR} -DBIN=${CMAKE_CURRENT_BINARY_DIR}
          -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/MakeRunTree.cmake"
  COMMENT "Assembling the run tree in ${CMAKE_CURRENT_BINARY_DIR}/data"
  VERBATIM)

#===============================================================================
# Install
#===============================================================================
include(GNUInstallDirs)
if(LITE_PORTABLE OR WIN32)
  set(lite_bindir ".")
  set(lite_docdir "doc")
  set(lite_datadir "data")
else()
  set(lite_bindir "${CMAKE_INSTALL_BINDIR}")
  set(lite_docdir "${CMAKE_INSTALL_DOCDIR}")
  set(lite_datadir "${CMAKE_INSTALL_DATADIR}/lite-xl")
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    install(FILES resources/icons/lite-xl.svg
            DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps")
    install(FILES resources/linux/org.lite_xl.lite_xl.desktop
            DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")
    install(FILES resources/linux/org.lite_xl.lite_xl.appdata.xml
            DESTINATION "${CMAKE_INSTALL_DATADIR}/metainfo")
  endif()
endif()

install(TARGETS lite-xl RUNTIME DESTINATION "${lite_bindir}")
install(FILES licenses/licenses.md DESTINATION "${lite_docdir}")
install(DIRECTORY docs/api/ DESTINATION "${lite_datadir}")   # contents, not the directory
install(DIRECTORY data/core DESTINATION "${lite_datadir}" PATTERN start.lua EXCLUDE)
foreach(d fonts plugins colors)
  install(DIRECTORY data/${d} DESTINATION "${lite_datadir}")
endforeach()
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/start.lua" DESTINATION "${lite_datadir}/core")
