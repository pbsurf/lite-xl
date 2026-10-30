#!/bin/bash
# Build lite-xl and run it straight from the source tree, with a separate user dir.
#
# lite-xl finds its data dir relative to the real executable path (<prefix>/bin
# -> <prefix>/share/lite-xl), so we assemble a prefix in build/run: a copy of the
# binary plus symlinks into data/, so edits to Lua files under data/ take effect
# on restart without rebuilding.  Only core/start.lua comes from the build dir,
# since the build generates it (version substitution).  The build is CMake's
# (CMakeLists.txt; meson.build is upstream's, no longer used here), configured
# on the first run.
#
# Usage: scripts/run.sh [lite-xl args...]     e.g. scripts/run.sh ~/projects/foo
#
# Environment:
#   LITE_BUILD    CMake build dir (default: build/; e.g. build-prof/ for profiling)
#   LITE_BUILD_TYPE  CMAKE_BUILD_TYPE when configuring it (default: RelWithDebInfo)
#   LITE_USERDIR  user config dir (default: user/ next to this repo)
#   LITE_CLANGD   clangd for the lsp plugin (default: the Android NDK's, 17.0.2)
set -e

src=$(dirname "$(dirname "$(readlink -f "$0")")")
build=${LITE_BUILD:-$src/build}
prefix=$build/run
datadir=$prefix/share/lite-xl

if [ ! -f "$build/CMakeCache.txt" ]; then
  if [ -e "$build/build.ninja" ]; then
    echo "$build is a meson build dir; remove it (or set LITE_BUILD) to build with CMake" >&2
    exit 1
  fi
  # compile_commands.json: clangd finds it in build/
  cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE="${LITE_BUILD_TYPE:-RelWithDebInfo}" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON >&2
fi
cmake --build "$build" >&2

mkdir -p "$prefix/bin" "$datadir/core"
# copy then rename so this works while another instance is running; only when
# changed, so running instances keep a binary on disk (perf, gdb need it)
if ! cmp -s "$build/lite-xl" "$prefix/bin/lite-xl"; then
  cp "$build/lite-xl" "$prefix/bin/lite-xl.new"
  mv -f "$prefix/bin/lite-xl.new" "$prefix/bin/lite-xl"
fi

find "$datadir" -maxdepth 1 -type l ! -exec test -e {} \; -delete  # drop stale links
for d in plugins colors fonts; do ln -sfn "$src/data/$d" "$datadir/$d"; done
find "$datadir/core" -maxdepth 1 -type l ! -exec test -e {} \; -delete  # drop stale links
for f in "$src"/data/core/*; do ln -sfn "$f" "$datadir/core/"; done
ln -sfn "$build/start.lua" "$datadir/core/start.lua"

: "${LITE_USERDIR:=$(dirname "$src")/user}"
: "${LITE_CLANGD:=$HOME/android-sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64/bin/clangd}"
export LITE_USERDIR LITE_CLANGD

# Native modules of our add-ons are built into <build>/addons/plugins/<add-on>, a
# directory of add-ons the user module adds as EXEDIR/addons (core.add_addon_dir),
# where package.cpath finds them. Links to them that run.sh used to put into the
# user dir's installed plugins are removed once they dangle.
ln -sfn "$build/addons" "$prefix/bin/addons"
for p in terminal spellcheck; do
  [ -d "$LITE_USERDIR/plugins/$p" ] && find "$LITE_USERDIR/plugins/$p" -maxdepth 1 -name '*.so' -xtype l -delete
done

# Headless (SDL_VIDEO_DRIVER=offscreen), SDL backs the window surface with a GPU
# renderer; on this VMware guest (vmwgfx) every presented frame then leaks a
# window-sized buffer in the kernel (GiBs after a few hundred frames), invisible in
# RSS. A plain software surface avoids the GPU entirely.
if [ "$SDL_VIDEO_DRIVER" = offscreen ]; then
  export SDL_FRAMEBUFFER_ACCELERATION=${SDL_FRAMEBUFFER_ACCELERATION:-0}
fi

exec "$prefix/bin/lite-xl" "$@"
