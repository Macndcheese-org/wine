#!/bin/bash
# Build the Direct3D set of the MNC Wine application from a GPTK release.
#
#   import-gptk.sh --gptk <Evaluation_environment_...dmg | extracted folder> \
#                  --base <mnc-d3d folder> --out <folder>
#
# --base is the mnc-d3d package (DXMT, DXVK and wined3d builds, plus the GPTK files of an older
# release).  The GPTK files in it are replaced by the ones of the release given with --gptk:
#
#   d3d10.dll d3d11.dll d3d12.dll dxgi.dll  ->  <name>_d3dm.dll   (what ntdll routes DX12 to)
#   d3d10core.dll (if the release has one)  ->  d3d10core_d3dm.dll
#   d3d12core.dll                           ->  d3d12core.dll     (new in GPTK 4.0 beta 3, loaded by
#                                                                 d3d12.dll under that exact name)
#   nvapi64.dll nvngx-on-metalfx.dll        ->  kept as they are
#   libd3dshared.dylib, D3DMetal.framework  ->  external/
#
# Result: <out>/windows/*.dll (goes to lib/wine/x86_64-windows) and <out>/external/
# (goes to lib/external), plus <out>/SOURCES.txt saying where each file came from.
set -euo pipefail

gptk= base= out=
while [ $# -gt 0 ]; do
  case $1 in
    --gptk) gptk=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --out)  out=$2;  shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$gptk" ] && [ -n "$base" ] && [ -n "$out" ] || { sed -n '2,20p' "$0"; exit 2; }

work=$(mktemp -d)
mounted=
cleanup() {
  [ -n "$mounted" ] && hdiutil detach -quiet "$mounted" || true
  rm -rf "$work"
}
trap cleanup EXIT

if [ -f "$gptk" ]; then
  if command -v hdiutil >/dev/null; then
    mounted=$work/dmg
    mkdir "$mounted"
    hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mounted" "$gptk"
    src=$mounted
  else
    # 7z reports errors for the symbolic links in the image; the files are extracted anyway.
    7z x -y -o"$work/dmg" "$gptk" >/dev/null || true
    src=$work/dmg
  fi
else
  src=$gptk
fi

redist=$(find "$src" -type d -name redist -print -quit)
[ -n "$redist" ] || { echo "no redist folder in $gptk" >&2; exit 1; }
dlls=$redist/lib/wine/x86_64-windows
ext=$redist/lib/external
[ -f "$ext/libd3dshared.dylib" ] && [ -d "$ext/D3DMetal.framework" ] || { echo "GPTK files missing in $redist" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/windows" "$out/external"
# the base set; macOS archives add ._ files that are not part of it
(cd "$base" && find . -maxdepth 1 -name '*.dll' ! -name '._*' -exec cp -p {} "$out/windows/" \;)
: > "$out/SOURCES.txt"
note() {   # a later note for the same file replaces the earlier one
  grep -v "^$1 " "$out/SOURCES.txt" > "$out/SOURCES.tmp" || true
  printf '%-28s %s\n' "$1" "$2" >> "$out/SOURCES.tmp"
  mv "$out/SOURCES.tmp" "$out/SOURCES.txt"
}
for f in "$out"/windows/*.dll; do note "$(basename "$f")" "mnc-d3d"; done

place() {   # place <file in the GPTK release> <name in the set>
  if [ -f "$dlls/$1" ]; then
    # In mnc-d3d the plain name (d3d11.dll, dxgi.dll, d3d12.dll) is the D3DMetal file as well, the
    # one a program gets when no backend is named; it must move to the new release together
    # with its _d3dm copy.  d3d10.dll and d3d10core.dll plain are Wine's own and stay.
    plain=${2%_d3dm.dll}.dll
    if [ "$plain" != "$2" ] && [ -f "$out/windows/$2" ] && [ -f "$out/windows/$plain" ] &&
       cmp -s "$out/windows/$2" "$out/windows/$plain"; then
      cp -p "$dlls/$1" "$out/windows/$plain"
      note "$plain" "GPTK release ($1)"
    fi
    cp -p "$dlls/$1" "$out/windows/$2"
    note "$2" "GPTK release ($1)"
  fi
}
place d3d10.dll  d3d10_d3dm.dll
place d3d11.dll  d3d11_d3dm.dll
place d3d12.dll  d3d12_d3dm.dll
place dxgi.dll   dxgi_d3dm.dll
place d3d12core.dll d3d12core.dll
place nvapi64.dll nvapi64.dll
place nvngx-on-metalfx.dll nvngx-on-metalfx.dll
if [ -f "$dlls/d3d10core.dll" ]; then
  place d3d10core.dll d3d10core_d3dm.dll
else
  echo "note: this GPTK release has no d3d10core.dll, d3d10core_d3dm.dll stays the one of mnc-d3d" >&2
fi

cp -p "$ext/libd3dshared.dylib" "$out/external/"
cp -Rp "$ext/D3DMetal.framework" "$out/external/"
note "external/libd3dshared.dylib" "GPTK release"
note "external/D3DMetal.framework" "GPTK release"

if [ -f "$gptk" ]; then
  { echo; echo "GPTK image: $(basename "$gptk")"; shasum -a 256 "$gptk" 2>/dev/null || sha256sum "$gptk"; } >> "$out/SOURCES.txt"
fi
cat "$out/SOURCES.txt"
