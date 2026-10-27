# Makes the build directory runnable in place, like scripts/run.sh does on Linux: a data/
# directory next to the executable (where it looks for it) that follows the source tree.
# plugins, colors and fonts are links to the source, so Lua edits there need only a restart;
# core is copied (refreshed at every build), as it must hold the generated start.lua.
# Usage: cmake -DSRC=<source dir> -DBIN=<build dir> -P MakeRunTree.cmake

set(data "${BIN}/data")
file(MAKE_DIRECTORY "${data}")

foreach(d plugins colors fonts)
  set(link "${data}/${d}")
  if(EXISTS "${link}")
    continue()
  endif()
  if(CMAKE_HOST_WIN32)
    # a junction needs no privilege, unlike a symlink
    file(TO_NATIVE_PATH "${link}" link_native)
    file(TO_NATIVE_PATH "${SRC}/data/${d}" target_native)
    execute_process(COMMAND cmd /c mklink /J "${link_native}" "${target_native}"
                    OUTPUT_QUIET RESULT_VARIABLE rc)
  else()
    execute_process(COMMAND "${CMAKE_COMMAND}" -E create_symlink "${SRC}/data/${d}" "${link}"
                    RESULT_VARIABLE rc)
  endif()
  if(NOT rc EQUAL 0)
    message(WARNING "could not link ${link}; copying instead")
    file(COPY "${SRC}/data/${d}" DESTINATION "${data}")
  endif()
endforeach()

file(REMOVE_RECURSE "${data}/core")
file(COPY "${SRC}/data/core" DESTINATION "${data}" PATTERN start.lua EXCLUDE)
file(COPY "${BIN}/start.lua" DESTINATION "${data}/core")
