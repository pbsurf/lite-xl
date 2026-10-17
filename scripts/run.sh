#!/bin/bash
# Build lite-xl and run it straight from the source tree, with a separate user dir.
#
# lite-xl finds its data dir relative to the real executable path (<prefix>/bin
# -> <prefix>/share/lite-xl), so we assemble a prefix in build/run: a copy of the
# binary plus symlinks into data/, so edits to Lua files under data/ take effect
# on restart without rebuilding.  Only core/start.lua comes from the build dir,
# since meson generates it (version substitution).
#
# Usage: scripts/run.sh [lite-xl args...]     e.g. scripts/run.sh ~/projects/foo
#
# Environment:
#   LITE_BUILD    meson build dir (default: build/; e.g. build-prof/ for profiling)
#   LITE_USERDIR  user config dir (default: user/ next to this repo)
#   LITE_CLANGD   clangd for the lsp plugin (default: the Android NDK's, 17.0.2)
set -e

src=$(dirname "$(dirname "$(readlink -f "$0")")")
build=${LITE_BUILD:-$src/build}
prefix=$build/run
datadir=$prefix/share/lite-xl

[ -d "$build" ] || meson setup "$build" "$src"
ninja -C "$build" >&2

mkdir -p "$prefix/bin" "$datadir/core"
# copy then rename so this works while another instance is running
cp "$build/src/lite-xl" "$prefix/bin/lite-xl.new"
mv -f "$prefix/bin/lite-xl.new" "$prefix/bin/lite-xl"

find "$datadir" -maxdepth 1 -type l ! -exec test -e {} \; -delete  # drop stale links
for d in plugins colors fonts; do ln -sfn "$src/data/$d" "$datadir/$d"; done
find "$datadir/core" -maxdepth 1 -type l ! -exec test -e {} \; -delete  # drop stale links
for f in "$src"/data/core/*; do ln -sfn "$f" "$datadir/core/"; done
ln -sfn "$build/start.lua" "$datadir/core/start.lua"

: "${LITE_USERDIR:=$(dirname "$src")/user}"
: "${LITE_CLANGD:=$HOME/android-sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64/bin/clangd}"
export LITE_USERDIR LITE_CLANGD

# Native modules of our add-ons (addons/meson.build) go next to the installed plugin,
# where package.cpath finds them. lpm's --symlink install makes the plugin dir a
# real dir of links to the files present at install time, so link the module there
# rather than into addons/.
if [ -d "$LITE_USERDIR/plugins/terminal" ]; then
  ln -sf "$build"/addons/libterminal.*.so "$LITE_USERDIR/plugins/terminal/"
fi
if [ -d "$LITE_USERDIR/plugins/spellcheck" ]; then
  ln -sf "$build"/addons/hunspell.*.so "$LITE_USERDIR/plugins/spellcheck/"
fi

# Headless (SDL_VIDEO_DRIVER=offscreen), SDL backs the window surface with a GPU
# renderer; on this VMware guest (vmwgfx) every presented frame then leaks a
# window-sized buffer in the kernel (GiBs after a few hundred frames), invisible in
# RSS. A plain software surface avoids the GPU entirely.
if [ "$SDL_VIDEO_DRIVER" = offscreen ]; then
  export SDL_FRAMEBUFFER_ACCELERATION=${SDL_FRAMEBUFFER_ACCELERATION:-0}
fi

exec "$prefix/bin/lite-xl" "$@"
