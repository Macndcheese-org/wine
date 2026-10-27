#!/bin/bash
# Build the Direct3D set and the Rosetta folder of the MNC Wine application from a MacNdCheese
# engine release (the wine-unified-osx64.tar.xz of a release, or the folder it extracts to).
#
#   assemble-d3d.sh --engine <wine-unified-osx64.tar.xz | folder> --out <folder> \
#                   [--rosetta-out <folder>] [--dxmt <folder>] [--gptk 3|4]
#
# Unlike import-gptk.sh, which needs Apple's GPTK image, this takes the GPTK files that the engine
# already ships (mnc-d3d layout 2, see mnc-d3d/LAYOUT in the engine): nothing is downloaded from
# Apple.  The result is what build-app.sh takes as --d3d-dir:
#
#   <out>/windows/    d3d11_dxmt.dll, d3d11_d3dm.dll, ... d3d12core.dll, nvapi64.dll, winemetal*.dll
#   <out>/unix/       winemetal.so, winemetal9.so
#   <out>/windows32/  the 32-bit winemetal*.dll
#   <out>/external/   libd3dshared.dylib, D3DMetal.framework
#   <out>/SOURCES.txt where each part comes from
#
# --rosetta-out receives mnc-rosetta (runtime_loader, libRuntimeRosettax87), for --rosetta-dir.
# --dxmt names a folder with newer DXMT builds (d3d9.dll d3d10core.dll d3d11.dll dxgi.dll, and
#   optionally winemetal.dll winemetal9.dll winemetal.so winemetal9.so) that replace the engine's.
# --gptk picks the toolkit: 4 (default, 4.0, needs macOS 26.4) or 3 (3.0).
set -euo pipefail

engine= out= rosetta_out= dxmt= gptk=4
while [ $# -gt 0 ]; do
  case $1 in
    --engine)      engine=$2; shift 2 ;;
    --out)         out=$2; shift 2 ;;
    --rosetta-out) rosetta_out=$2; shift 2 ;;
    --dxmt)        dxmt=$2; shift 2 ;;
    --gptk)        gptk=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$engine" ] && [ -n "$out" ] || { sed -n '2,22p' "$0"; exit 2; }
case $gptk in 3) d3dm=d3dm ;; 4) d3dm=d3dm-gptk4 ;; *) echo "--gptk is 3 or 4" >&2; exit 2 ;; esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ -f "$engine" ]; then
  # only what is needed: the archive is 600 MB
  tar -xJf "$engine" -C "$work" ./mnc-d3d ./mnc-rosetta ./dlls/winemetal ./dlls/winemetal9
  src=$work
else
  src=$engine
fi
d3d=$src/mnc-d3d
[ -f "$d3d/VERSION" ] && grep -q '^layout: 2' "$d3d/VERSION" || { echo "$engine has no mnc-d3d of layout 2" >&2; exit 1; }
for d in base dxmt opengl "$d3dm" "$d3dm/external"; do
  [ -d "$d3d/$d" ] || { echo "$d3d/$d is missing" >&2; exit 1; }
done

rm -rf "$out"
mkdir -p "$out/windows" "$out/unix" "$out/windows32" "$out/external"
: > "$out/SOURCES.txt"
note() { printf '%-28s %s\n' "$1" "$2" >> "$out/SOURCES.txt"; }
put() {   # put <source file> <folder in out> <name> <note>
  cp -p "$1" "$out/$2/$3"
  note "$3" "$4"
}

# the layout-2 folders hold canonical names; the loader looks for <name>_<backend>.dll
for m in d3d10core d3d11 dxgi; do
  put "$d3d/dxmt/$m.dll" windows "${m}_dxmt.dll" "dxmt"
  put "$d3d/opengl/$m.dll" windows "${m}_opengl.dll" "opengl"
done
put "$d3d/dxmt/d3d9.dll" windows d3d9_dxmt.dll "dxmt"
put "$d3d/opengl/wined3d.dll" windows wined3d_opengl.dll "opengl"
for m in d3d10 d3d10core d3d11 d3d12 dxgi; do
  put "$d3d/$d3dm/$m.dll" windows "${m}_d3dm.dll" "$d3dm"
done
# d3d12.dll without a name is the GPTK stub too: what a program gets when no backend is named
put "$d3d/$d3dm/d3d12.dll" windows d3d12.dll "$d3dm"
for f in nvapi64.dll nvngx-on-metalfx.dll atidxx64.dll; do
  [ -f "$d3d/$d3dm/$f" ] && put "$d3d/$d3dm/$f" windows "$f" "$d3dm"
done
put "$d3d/base/d3d12core.dll" windows d3d12core.dll "base"
for f in winemetal.dll winemetal9.dll; do put "$d3d/base/$f" windows "$f" "base"; done
cp -p "$src/dlls/winemetal/winemetal.so" "$src/dlls/winemetal9/winemetal9.so" "$out/unix/"
note "unix/winemetal.so" "engine dlls/winemetal"
note "unix/winemetal9.so" "engine dlls/winemetal9"
for d in winemetal winemetal9; do
  [ -f "$src/dlls/$d/i386-windows/$d.dll" ] && put "$src/dlls/$d/i386-windows/$d.dll" windows32 "$d.dll" "engine dlls/$d (32-bit)"
done
cp -p "$d3d/$d3dm/external/libd3dshared.dylib" "$out/external/"
cp -Rp "$d3d/$d3dm/external/D3DMetal.framework" "$out/external/"
note "external/libd3dshared.dylib" "$d3dm"
note "external/D3DMetal.framework" "$d3dm"

if [ -n "$dxmt" ]; then
  for m in d3d10core d3d11 dxgi d3d9; do
    [ -f "$dxmt/$m.dll" ] || { echo "$dxmt/$m.dll is missing" >&2; exit 1; }
    put "$dxmt/$m.dll" windows "${m}_dxmt.dll" "$dxmt"
  done
  for f in winemetal.dll winemetal9.dll; do [ -f "$dxmt/$f" ] && put "$dxmt/$f" windows "$f" "$dxmt"; done
  for f in winemetal.so winemetal9.so; do [ -f "$dxmt/$f" ] && put "$dxmt/$f" unix "$f" "$dxmt"; done
fi

{
  echo
  echo "engine: $(basename "$engine")"
  sed -n 's/^\(gptk[34]\|dxmt\|built\): /\1 /p' "$d3d/VERSION"
} >> "$out/SOURCES.txt"

if [ -n "$rosetta_out" ]; then
  rm -rf "$rosetta_out"
  mkdir -p "$rosetta_out"
  cp -p "$src/mnc-rosetta/"* "$rosetta_out/"
fi
cat "$out/SOURCES.txt"
