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
#   LITE_USERDIR  user config dir (default: user/ next to this repo)
#   LITE_CLANGD   clangd for the lsp plugin (default: the Android NDK's, 17.0.2)
set -e

src=$(dirname "$(dirname "$(readlink -f "$0")")")
build=$src/build
prefix=$build/run
datadir=$prefix/share/lite-xl

[ -d "$build" ] || meson setup "$build" "$src"
ninja -C "$build" >&2

mkdir -p "$prefix/bin" "$datadir/core"
# copy then rename so this works while another instance is running
cp "$build/src/lite-xl" "$prefix/bin/lite-xl.new"
mv -f "$prefix/bin/lite-xl.new" "$prefix/bin/lite-xl"

for d in plugins libraries colors fonts; do ln -sfn "$src/data/$d" "$datadir/$d"; done
find "$datadir/core" -maxdepth 1 -type l ! -exec test -e {} \; -delete  # drop stale links
for f in "$src"/data/core/*; do ln -sfn "$f" "$datadir/core/"; done
ln -sfn "$build/start.lua" "$datadir/core/start.lua"

: "${LITE_USERDIR:=$(dirname "$src")/user}"
: "${LITE_CLANGD:=$HOME/android-sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64/bin/clangd}"
export LITE_USERDIR LITE_CLANGD

exec "$prefix/bin/lite-xl" "$@"
