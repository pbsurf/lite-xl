# Installs the add-ons into a user dir by copying, for a machine without lpm (the Windows
# counterpart of the user dir's addons.sh).  Ours come from this checkout, as listed in its
# manifest.json; the few upstream ones are downloaded at the commits lpm would use, and
# checked against their hashes.  Run again after changing the list or the add-ons (a copy
# doesn't follow the checkout).
#
#   cmake -DSRC=<lite-xl checkout> -DUSERDIR=<user dir> [-DBUILD=<build dir>] [-DADDONS="id;id;..."] \
#         -P InstallAddons.cmake
#
# With BUILD, the native modules built into <build>/addons (libterminal) are copied in too.
#
# Keep ADDONS' default in step with the --symlink list in the user dir's addons.sh.

cmake_minimum_required(VERSION 3.20)

foreach(v SRC USERDIR)
  if(NOT ${v})
    message(FATAL_ERROR "usage: cmake -DSRC=<checkout> -DUSERDIR=<user dir> [-DADDONS=a;b] -P InstallAddons.cmake")
  endif()
  get_filename_component(${v} "${${v}}" ABSOLUTE)
endforeach()

if(NOT ADDONS)
  set(ADDONS
    widget shapes lsp lintplus build debugger repl language_yaml tab_switcher tab_overflow
    menubar headerbar highlight_selection search_ui ephemeral_tabs navigate nerdicons terminal
    spellcheck openurl gitfiles qtcreator)
endif()

# ---- upstream add-ons: <id> <dest under USERDIR> <url> <sha256> ---------------------------
# lite-xl-plugins at 6e4aa64 (what our copies of its add-ons are based on), lpm's repo for json
set(plugins_url https://raw.githubusercontent.com/lite-xl/lite-xl-plugins/6e4aa640d679decd67d2c0b677ede52ef70a7bf9)
set(json_url https://raw.githubusercontent.com/lite-xl/lite-xl-plugin-manager/4aa02c217c2ae5817f0f803f376770cf593da915)
set(font_dir libraries/font_symbols_nerdfont_mono_regular)
set(UPSTREAM
  "json|libraries/json.lua|${json_url}/libraries/json.lua|38f1cb35c58f065c2044fa708c1f0467bf9630d88f6e8ef0b9d59bd534a0a4e0"
  "bracketmatch|plugins/bracketmatch.lua|${plugins_url}/plugins/bracketmatch.lua|e81490a0280dba77b4a45b50662a96d2b5369306489a29b9ab2345b1ad36f5e4"
  "language_make|plugins/language_make.lua|${plugins_url}/plugins/language_make.lua|06754ef541a72a64e2e1eb2a3c065e622057eb140a0ac3f7c01ff292306a7dfb"
  # nerdicons' font: the mapping as the library's init.lua, the font file beside it
  "font_symbols_nerdfont_mono_regular|${font_dir}/init.lua|${plugins_url}/plugins/font_symbols_nerdfont_mono_regular.lua|00a33327397b69acef69c38700f1fbb10ed8a1a469c226e778fb32039d243e16"
  "font_symbols_nerdfont_mono_regular|${font_dir}/SymbolsNerdFontMono-Regular.ttf|https://github.com/ryanoasis/nerd-fonts/raw/cf3561b1a51f70d5398eb49d603679b0f0c55d74/patched-fonts/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf|f4f40e003e9d00000f1218a606127fab82b1faf0df2d9095a06190f4f2c32e36"
)
# which upstream add-ons the ones we install need (the ids are listed in the manifest's
# dependencies; the upstream ones have no manifest here)
set(upstream_ids json bracketmatch language_make font_symbols_nerdfont_mono_regular)
# installed on request, or as a dependency of an add-on of ours
set(UPSTREAM_DEFAULT json bracketmatch language_make)

# ---- our add-ons, from the manifest ------------------------------------------------------
file(READ "${SRC}/manifest.json" manifest)
string(JSON count LENGTH "${manifest}" addons)
math(EXPR last "${count} - 1")
set(ours)
foreach(i RANGE ${last})
  string(JSON id GET "${manifest}" addons ${i} id)
  string(JSON path ERROR_VARIABLE err GET "${manifest}" addons ${i} path)
  if(err)   # no path: not an installable add-on
    continue()
  endif()
  list(APPEND ours ${id})
  set(path_${id} "${path}")
  set(deps_${id})
  string(JSON deps ERROR_VARIABLE err GET "${manifest}" addons ${i} dependencies)
  if(NOT err)
    string(JSON ndeps LENGTH "${deps}")
    if(ndeps GREATER 0)
      math(EXPR dlast "${ndeps} - 1")
      foreach(d RANGE ${dlast})
        string(JSON dep MEMBER "${deps}" ${d})
        string(JSON optional ERROR_VARIABLE err GET "${deps}" ${dep} optional)
        if(err OR NOT optional OR optional STREQUAL "false")
          list(APPEND deps_${id} ${dep})
        endif()
      endforeach()
    endif()
  endif()
endforeach()

# the add-ons to install: the requested ones, the upstream ones always, dependencies checked
set(wanted ${ADDONS} ${UPSTREAM_DEFAULT})
list(REMOVE_DUPLICATES wanted)
foreach(id ${ADDONS})
  foreach(dep ${deps_${id}})
    if(NOT dep IN_LIST wanted)
      if(dep IN_LIST ours OR dep IN_LIST upstream_ids)
        message(STATUS "adding ${dep}, needed by ${id}")
        list(APPEND wanted ${dep})
      else()
        message(WARNING "${id} needs ${dep}, which is neither in the manifest nor upstream here")
      endif()
    endif()
  endforeach()
endforeach()

foreach(id ${wanted})
  if(id IN_LIST ours)
    if(NOT path_${id} MATCHES "^addons/(plugins|libraries|colors)/")
      message(FATAL_ERROR "${id}: unexpected path ${path_${id}} in the manifest")
    endif()
    set(kind ${CMAKE_MATCH_1})
    get_filename_component(name "${path_${id}}" NAME)
    set(from "${SRC}/${path_${id}}")
    set(dest "${USERDIR}/${kind}/${name}")
    file(REMOVE_RECURSE "${dest}")   # also drops files an update removed, or a hard link
    file(COPY "${from}" DESTINATION "${USERDIR}/${kind}")
    message(STATUS "installed ${id} (${kind}/${name})")
    # the add-on's native module, built into <build>/addons, goes into its directory
    if(BUILD AND id STREQUAL "terminal")
      file(GLOB modules "${BUILD}/addons/libterminal.*-*.*")
      list(FILTER modules EXCLUDE REGEX "\\.(pdb|ilk|exp|lib)$")
      if(modules)
        file(COPY ${modules} DESTINATION "${dest}")
        message(STATUS "  with its native module")
      else()
        message(WARNING "terminal: no libterminal in ${BUILD}/addons; build the libterminal target")
      endif()
    endif()
  elseif(id IN_LIST upstream_ids)
    foreach(entry ${UPSTREAM})
      string(REPLACE "|" ";" f "${entry}")
      list(GET f 0 eid)
      if(NOT eid STREQUAL id)
        continue()
      endif()
      list(GET f 1 rel)
      list(GET f 2 url)
      list(GET f 3 sha)
      set(dest "${USERDIR}/${rel}")
      if(EXISTS "${dest}")
        file(SHA256 "${dest}" have)
      else()
        set(have)
      endif()
      if(NOT have STREQUAL sha)
        get_filename_component(dir "${dest}" DIRECTORY)
        file(MAKE_DIRECTORY "${dir}")
        file(DOWNLOAD "${url}" "${dest}" EXPECTED_HASH SHA256=${sha} STATUS st)
        list(GET st 0 code)
        if(NOT code EQUAL 0)
          file(REMOVE "${dest}")
          message(FATAL_ERROR "downloading ${url}: ${st}")
        endif()
      endif()
      message(STATUS "installed ${id} (${rel})")
    endforeach()
  else()
    message(FATAL_ERROR "unknown add-on: ${id}")
  endif()
endforeach()
