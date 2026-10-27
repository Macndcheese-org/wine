# Packaging MNC Wine

Turns a build of this tree into **MNC Wine.app**, the application that is released as
`MNC-Wine-<version>-osx64.tar.xz`.

Opening the application opens Terminal with `wine` first in `PATH` and the welcome text of the WineHQ
application ("Wine Is Not an Emulator", how to run `.exe` and `.msi`, `winecfg`, `appdb`).
Opening a Windows program with it runs the program. Direct3D 9 to 11 programs run on DXMT and
Direct3D 12 programs on D3DMetal (GPTK), unless `MNC_GRAPHICS_ENGINE` says otherwise (see below). The
Win32-to-SwiftUI layer is on unless `MNC_NATIVE_UI=0`.

## What is in this directory

| File | What it does |
| --- | --- |
| `launcher/` | The program inside the bundle that opens Terminal or runs a program, and its `Info.plist`. `launcher/start/bin/winehelp` (the welcome text) and `appdb`, and `launcher/winehq.icns` (the Wine logo), are the files of the WineHQ application (LGPL, headers kept); `build-app.sh --icon` replaces the icon. |
| `bundle-dylibs.py` | Copies the third-party libraries into the bundle and points every binary at them with `@rpath`. Removes every absolute run path. |
| `verify-app.py` | Fails when the bundle still depends on the machine that built it (Homebrew, `/usr/local`, `DYLD_*`, bare-name `dlopen`, bad signature). |
| `assemble-d3d.sh` | Builds the Direct3D set (GPTK/D3DMetal, DXMT, winemetal) and the Rosetta folder from the engine release named in the workflow (`ENGINE_REPO`, `ENGINE_TAG`), with no download from Apple. This is what the GitHub Actions build uses. |
| `import-gptk.sh` | Builds the Direct3D set from a GPTK image and the `mnc-d3d` package. |
| `build-app.sh` | Puts everything together, checks it, and writes the `.tar.xz`. |
| `prerelease.sh` | Names and publishes the GitHub pre-release of a CI build (see below). |

## Why there are no DYLD variables

Wine opens libraries such as FreeType, GnuTLS, SDL and MoltenVK by bare name
(`dlopen("libfreetype.6.dylib")`). dyld looks bare names up through `DYLD_FALLBACK_LIBRARY_PATH`,
whose default is `/usr/local/lib`: on a Mac with Homebrew that finds Homebrew's copy, and on one
without it finds nothing. The build therefore rewrites every `SONAME_LIB*` in `include/config.h` into an
`@rpath/` name (the `sed` line in `.github/workflows/build-release.yml`), and `bundle-dylibs.py`
gives the unix libraries a run path that leads to the bundled copies. `verify-app.py` fails if a
bare name is left.

D3DMetal is found the same way: when the backend app does not export
`CX_APPLEGPTK_LIBD3DSHARED_PATH`, ntdll uses `<prefix>/lib/external/libd3dshared.dylib`.

## Pre-releases from CI

Every push to `mnc-11.20` (`RELEASE_BRANCH` in `.github/workflows/build-release.yml`) publishes the
build as the pre-release **MacNdCheese Wine 11.20.0**, tag `11.20.0`, with
`MNC-Wine-11.20.0-osx64.tar.xz` attached. The next build replaces it. To keep one, edit the release on
GitHub and untick "pre-release": the builds that follow are then published as `11.20.1`, and after that
one is made stable, `11.20.2`, and so on. A new Wine version restarts at `.0` (the number comes from `VERSION`).
Other `mnc-*` branches only keep the build as a run artifact.

## Making a release by hand (on a Mac)

```sh
# 1. build, as in the workflow, then install into a staging folder
make -C build64 install DESTDIR="$PWD/dist"

# 2. the Direct3D set: GPTK 4.0 beta 3 over the mnc-d3d package
packaging/import-gptk.sh --gptk ~/Downloads/Evaluation_environment_for_Windows_games_4.0_beta_3.dmg \
    --base ~/path/to/mnc-d3d --out d3d-set

# 3. the application (w2s: folder with win32swiftui.dll and win32swiftui.so)
packaging/build-app.sh --install-dir dist/opt/mnc-wine --d3d-dir d3d-set --w2s-dir ~/path/to/w2s \
    --config-h build64/include/config.h --version 11.20.0 --out out --archive
```

## Direct3D backend choice

* `MNC_GRAPHICS_ENGINE=d3dmetal|dxmt|dxvk|vr|opengl` (set by the backend app for every launch) decides, as before.
* Without it, a 64-bit program gets DXMT, unless it imports `d3d12.dll` (also delay-imported) or has
  `D3D12Core.dll` next to it, in which case it gets D3DMetal. 32-bit programs keep Wine's own d3d.
  A program that loads `d3d12.dll` later with `LoadLibrary` must be started with `MNC_GRAPHICS_ENGINE=d3dmetal`.
* To run one program on GPTK instead: `MNC_GRAPHICS_ENGINE=d3dmetal wine program.exe`.
* The 64-bit `lib/wine/x86_64-windows` holds no unsuffixed `d3d11.dll`, `dxgi.dll` or `d3d10core.dll`. Wine finds
  the builtin of `d3d11_dxmt.dll` (and of `d3d11_d3dm.dll`) by the name written inside the file, `d3d11.dll`, so an
  unsuffixed file of that name would be loaded in their place: before this was fixed every program that was sent to
  DXMT, Steam included, ran on GPTK. `verify-app.py` fails if one comes back.
