#!/bin/bash
# Build Lite XL's Linux release packages with the CMake build, as release.yml's build_linux
# job does (in the manylinux build box, so the binary runs on old distros):
#
#   lite-xl-<version>-linux-<arch>-portable.tar.gz          the editor, portable layout
#   lite-xl-<version>-addons-linux-<arch>-portable.tar.gz   plus 3rd party add-ons
#   LiteXL-<version>-<arch>.AppImage, LiteXL-<version>-addons-<arch>.AppImage
#
# SDL, FreeType, PCRE2 and Lua are built in statically (LITE_SYSTEM_*=OFF), so the binary
# needs only libc, libm and libdl (SDL loads X11/Wayland libraries at runtime). It's built
# once: the data dir is found at runtime (<exe>/data, or ../share/lite-xl from bin/), so
# the portable and /usr layouts differ only in where it's installed.
#
# Usage: scripts/release-linux.sh [--version VERSION] [--no-addons] [--no-appimage] [--debug]
# (CI's build.yml makes only the plain portable archive: --no-addons --no-appimage)
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Lite XL."; exit 1
fi

source scripts/common.sh

version=""
appimage=true
variants="false true"   # without and with the 3rd party add-ons
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version) version="-$2"; shift 2 ;;
    --no-addons) variants=false; shift ;;
    --no-appimage) appimage=false; shift ;;
    --debug) set -x; shift ;;
    *) echo "usage: $0 [--version VERSION] [--no-addons] [--no-appimage] [--debug]" >&2; exit 1 ;;
  esac
done

arch="$(uname -m)"
build_dir=build-release

cmake -S . -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
  -DLITE_SYSTEM_SDL=OFF -DLITE_SYSTEM_FREETYPE=OFF -DLITE_SYSTEM_PCRE2=OFF \
  -DLITE_LPM=OFF -DLITE_SPELLCHECK=OFF
cmake --build "$build_dir" --target lite-xl

# install <dest dir> <portable: ON|OFF> [prefix]: the editor, stripped, into <dest dir>
install_to() {
  rm -rf "$1"
  cmake -B "$build_dir" -DLITE_PORTABLE="$2" >/dev/null
  if [[ $2 == ON ]]; then
    cmake --install "$build_dir" --prefix "$(pwd)/$1" --strip
  else
    DESTDIR="$(pwd)/$1" cmake --install "$build_dir" --prefix "$3" --strip
  fi
}

# portable archives
for addons in $variants; do
  name=lite-xl$version
  [[ $addons == true ]] && name+=-addons
  name+=-linux-$arch-portable
  install_to lite-xl ON
  if [[ $addons == true ]]; then
    addons_download "$build_dir"
    addons_install "$build_dir" "lite-xl/data"
  fi
  rm -f "$name.tar.gz"
  tar czf "$name.tar.gz" lite-xl
  echo "Created $name.tar.gz"
done

[[ $appimage == true ]] || exit 0

if [ ! -e appimagetool ]; then
  wget -O appimagetool \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${arch}.AppImage"
  chmod 0755 appimagetool
fi

for addons in $variants; do
  name=LiteXL$version
  [[ $addons == true ]] && name+=-addons
  name+=-$arch.AppImage
  install_to LiteXL.AppDir OFF /usr
  # appimagetool takes a PNG (or XPM) icon, with .DirIcon as the AppImage's own
  cp resources/icons/lite-xl.png resources/linux/org.lite_xl.lite_xl.desktop LiteXL.AppDir/
  ln -s lite-xl.png LiteXL.AppDir/.DirIcon
  cat > LiteXL.AppDir/AppRun <<'EOF'
#!/bin/sh
CURRENTDIR="$(dirname "$(readlink -f "$0")")"
exec "$CURRENTDIR/usr/bin/lite-xl" "$@"
EOF
  chmod +x LiteXL.AppDir/AppRun
  if [[ $addons == true ]]; then
    addons_download "$build_dir"
    addons_install "$build_dir" "LiteXL.AppDir/usr/share/lite-xl"
  fi
  rm -f "$name"
  APPIMAGE_EXTRACT_AND_RUN=1 ./appimagetool LiteXL.AppDir "$name"
  echo "Created $name"
done
