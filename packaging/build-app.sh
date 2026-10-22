#!/bin/bash
# Assemble "MNC Wine.app" from an installed Wine tree.
#
#   build-app.sh --install-dir <dir> --version 11.20.0 --out <folder> [options]
#
#   --install-dir  the result of "make install DESTDIR=..." reduced to the prefix: it holds bin/, lib/, share/
#   --version      version of the application, for example 11.20.0
#   --out          folder that receives MNC Wine.app
#   --d3d-dir      output of import-gptk.sh (DXMT, D3DMetal and the rest of the Direct3D set)
#   --addons-dir   folder with mono/wine-mono-<version>-x86.msi and gecko/wine-gecko-<version>-<arch>.msi
#   --w2s-dir      folder with win32swiftui.dll and win32swiftui.so (and i386/win32swiftui.dll), from the Win32-to-SwiftUI build
#   --config-h     include/config.h of the build, to bundle the libraries Wine opens with dlopen
#   --search       where to find the libraries to bundle (repeatable; default: the Homebrew prefix lib)
#   --icon         .icns file for the application (optional)
#   --archive      also write MNC-Wine-<version>-osx64.tar.xz next to the application
#
# The bundle is checked at the end with verify-app.py; the script fails if the check does.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
install= version= out= d3d= w2s= addons= config_h= icon= archive=0
search=()
while [ $# -gt 0 ]; do
  case $1 in
    --install-dir) install=$2; shift 2 ;;
    --version)     version=$2; shift 2 ;;
    --out)         out=$2; shift 2 ;;
    --d3d-dir)     d3d=$2; shift 2 ;;
    --w2s-dir)     w2s=$2; shift 2 ;;
    --addons-dir)  addons=$2; shift 2 ;;
    --config-h)    config_h=$2; shift 2 ;;
    --search)      search+=("$2"); shift 2 ;;
    --icon)        icon=$2; shift 2 ;;
    --archive)     archive=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$install" ] && [ -n "$version" ] && [ -n "$out" ] || { sed -n '2,16p' "$0"; exit 2; }
[ -x "$install/bin/wine" ] || { echo "$install/bin/wine is missing" >&2; exit 1; }
if [ ${#search[@]} -eq 0 ]; then
  if command -v brew >/dev/null; then search=("$(brew --prefix)/lib"); else search=(/usr/local/lib); fi
fi

app=$out/MNC\ Wine.app
res=$app/Contents/Resources
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$res"
cp -Rp "$install" "$res/wine"
# Development files are not part of the application: the compiler driver and the IDL/resource
# tools carry /usr/local default search paths, and nobody builds programs with this app.
(cd "$res/wine" && rm -rf include bin/winegcc bin/wineg++ bin/winecpp bin/widl bin/wrc bin/wmc \
   bin/winebuild bin/winemaker bin/function_grep.pl && find lib -name '*.a' -delete)

arch_dir=$res/wine/lib/wine
if [ -n "$d3d" ]; then
  cp -p "$d3d"/windows/*.dll "$arch_dir/x86_64-windows/"
  # the unix side of DXMT (winemetal.so, winemetal9.so)
  [ -d "$d3d/unix" ] && cp -p "$d3d"/unix/*.so "$arch_dir/x86_64-unix/"
  mkdir -p "$res/wine/lib/external"
  cp -Rp "$d3d"/external/. "$res/wine/lib/external/"
fi
if [ -n "$w2s" ]; then
  cp -p "$w2s/win32swiftui.dll" "$arch_dir/x86_64-windows/"
  cp -p "$w2s/win32swiftui.so"  "$arch_dir/x86_64-unix/"
  # 32-bit programs (installers, old games) get the layer too when the folder has it
  [ -f "$w2s/i386/win32swiftui.dll" ] && cp -p "$w2s/i386/win32swiftui.dll" "$arch_dir/i386-windows/"
fi

# Wine Mono and Wine Gecko, as the installers wine looks for in share/wine/mono and share/wine/gecko:
# a new prefix then sets them up from the application instead of asking to download them
if [ -n "$addons" ]; then
  for d in mono gecko; do
    [ -d "$addons/$d" ] && mkdir -p "$res/wine/share/wine/$d" && cp -p "$addons/$d"/*.msi "$res/wine/share/wine/$d/"
  done
fi

# launcher and Info.plist
clang -arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -O2 \
  -framework Cocoa "$here/launcher/main.m" -o "$app/Contents/MacOS/MNC Wine"
icon_entry=
if [ -n "$icon" ]; then
  cp "$icon" "$res/MNCWine.icns"
  icon_entry='<key>CFBundleIconFile</key><string>MNCWine</string>'
fi
sed -e "s|@VERSION@|$version|g" -e "s|@ICON_ENTRY@|$icon_entry|" "$here/launcher/Info.plist.in" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

# third-party libraries, inside the bundle, found through run paths
bundle_args=(--prefix "$res/wine")
for s in "${search[@]}"; do bundle_args+=(--search "$s"); done
[ -n "$config_h" ] && bundle_args+=(--config-h "$config_h")
python3 "$here/bundle-dylibs.py" "${bundle_args[@]}"

# bundle-dylibs.py signed (ad hoc) every binary that install_name_tool changed, which Rosetta
# requires; the GPTK files are untouched and keep Apple's signature, so the bundle is not
# signed with --deep.
codesign --force --sign - "$app"
python3 "$here/verify-app.py" "$app"

if [ "$archive" = 1 ]; then
  tar -C "$out" -cJf "$out/MNC-Wine-$version-osx64.tar.xz" "MNC Wine.app"
  ls -la "$out/MNC-Wine-$version-osx64.tar.xz"
fi
