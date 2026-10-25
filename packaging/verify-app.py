#!/usr/bin/env python3
"""Check that an MNC Wine application bundle is fit to ship.

Fails (exit status 1) when anything in it still depends on the machine it was built on:

  * a binary links a library outside the bundle other than the system ones (/usr/lib, /System);
  * a binary has a run path that is not relative to itself;
  * a library is named by an @rpath that none of the run paths of the binary leads to;
  * Homebrew, MacPorts or /usr/local library locations are written into a binary or a script;
  * a library is opened by bare name (dlopen("libfoo.dylib")), which dyld resolves through
    DYLD_FALLBACK_LIBRARY_PATH, that is /usr/local/lib, that is Homebrew;
  * DYLD_* variables are set by the launcher or by any script of the bundle;
  * the bundle holds an unsigned or invalidly signed binary;
  * the Terminal welcome text (Contents/Resources/start/bin/winehelp, appdb) or the icon named by Info.plist is missing, or
    the launcher no longer runs winehelp (the application then opens Terminal without the WineHQ banner);
  * the 64-bit Direct3D files of one backend (d3d11_dxmt.dll, ...) sit next to an unsuffixed d3d11.dll,
    dxgi.dll or d3d10core.dll: Wine would load that one instead (see check_d3d_names).

Usage: verify-app.py "MNC Wine.app"
Environment: OTOOL and CODESIGN override the tools.
"""

import os
import plistlib
import re
import subprocess
import sys

OTOOL = os.environ.get("OTOOL", "otool")
CODESIGN = os.environ.get("CODESIGN", "codesign")
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
SYSTEM = ("/usr/lib/", "/System/", "/Library/Apple/")

BAD_LOCATION = re.compile(rb"/opt/homebrew|/usr/local/(?:Cellar|opt|lib|include)|/opt/local/|/Users/[^/\0]+/")
BARE_DYLIB = re.compile(rb"(?<![\w/@.+-])(lib[\w+.-]*\.dylib)\0")
DYLD_VAR = re.compile(rb"\bDYLD_[A-Z_]+")

# Strings that are not locations the bundle depends on.
# Bare names opened by bundled third-party libraries for features Wine does not use: SDL's video
# back ends (Wine uses SDL for game controllers only), x265's sibling libraries for other bit
# depths (encoding), and Apple's own D3DMetal files, which cannot be edited.
BARE_DYLIB_OK = {
    ("libSDL2-2.0.0.dylib", name) for name in (
        "libGLESv2.dylib", "libGLESv1_CM.dylib", "libGLES_CM.dylib", "libEGL.dylib",
        "libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib")
} | {
    ("libx265.216.dylib", name) for name in (
        "libx265.dylib", "libx265_main.dylib", "libx265_main10.dylib", "libx265_main12.dylib")
} | {
    ("libdxcompiler.dylib", "libdxcompiler.dylib"),
    ("libdxccontainer.dylib", "libdxcompiler.dylib"),
}
# Third-party libraries carry the prefix they were compiled for (translations, plug-in folders).
# Wine's own files and the scripts must be clean; these are only reported.
THIRD_PARTY_PREFIX = "Contents/Resources/wine/lib/"
DYLD_OK = {                      # ntdll.so points DYLD_LIBRARY_PATH at the build tree, only in a build tree
    ("ntdll.so", b"DYLD_LIBRARY_PATH"),
    ("ntdll.so", b"DYLD_INSERT_LIBRARIES"),
    ("ntdll.so", b"ROSETTA_X87_SAVED_DYLD_INSERT_LIBRARIES"),
}

errors = []
notes = []


def fail(msg):
    errors.append(msg)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True)


def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        return f.read(4) in MAGICS


def is_pe(path):
    """Windows programs and libraries carry the paths of the compiler that built them (debug and
    assert strings); they are not loaded by dyld."""
    with open(path, "rb") as f:
        return f.read(2) == b"MZ"


def load_commands(path):
    out = run(OTOOL, "-l", path).stdout.splitlines()
    libs, rpaths = [], []
    for i, line in enumerate(out):
        line = line.strip()
        if line in ("cmd LC_LOAD_DYLIB", "cmd LC_LOAD_WEAK_DYLIB", "cmd LC_REEXPORT_DYLIB", "cmd LC_LAZY_LOAD_DYLIB"):
            libs.append(out[i + 2].strip().split("name ", 1)[1].split(" (")[0])
        elif line == "cmd LC_RPATH":
            rpaths.append(out[i + 2].strip().split("path ", 1)[1].split(" (")[0])
    return libs, rpaths


def own_id(path):
    out = run(OTOOL, "-D", path).stdout.splitlines()
    return out[1].strip() if len(out) > 1 else None


def expand(rpath, binary):
    here = os.path.dirname(os.path.realpath(binary))
    return os.path.normpath(rpath.replace("@loader_path", here).replace("@executable_path", here))


def check_macho(path, rel):
    libs, rpaths = load_commands(path)
    # lib/external holds the GPTK files exactly as Apple signed them: their run paths include
    # Apple build-machine locations that don't exist anywhere, and cannot be edited without
    # breaking the signature.  They must still not point at Homebrew or /usr/local.
    apple = (os.sep + "lib" + os.sep + "external" + os.sep) in rel
    for r in rpaths:
        if r.startswith(("@loader_path", "@executable_path")):
            continue
        if apple and not BAD_LOCATION.search(r.encode()):
            continue
        fail("%s: run path %s is not relative" % (rel, r))
    ident = own_id(path)
    for lib in libs:
        if lib == ident or lib.startswith(SYSTEM):
            continue
        if lib.startswith("@rpath/"):
            name = lib[len("@rpath/"):]
            if not any(os.path.exists(os.path.join(expand(r, path), name)) for r in rpaths):
                fail("%s: %s is not found through its run paths" % (rel, lib))
        elif lib.startswith(("@loader_path/", "@executable_path/")):
            if not os.path.exists(os.path.join(os.path.dirname(os.path.realpath(path)), lib.split("/", 1)[1])):
                fail("%s: %s does not exist" % (rel, lib))
        else:
            fail("%s: links %s outside the bundle" % (rel, lib))
    if sys.platform == "darwin" or os.environ.get("CODESIGN"):
        # runtime_loader reads libRuntimeRosettax87 from disk and injects it as it is, so it is
        # unsigned in rosettax87_jit and must stay that way
        if os.path.basename(path) == "libRuntimeRosettax87":
            return
        if run(CODESIGN, "--verify", "--strict", path).returncode:
            fail("%s: signature missing or invalid" % rel)


def is_third_party(rel):
    return rel.startswith(THIRD_PARTY_PREFIX) and os.path.dirname(rel) == THIRD_PARTY_PREFIX.rstrip("/")


def check_bytes(path, rel, binary):
    with open(path, "rb") as f:
        data = f.read()
    base = os.path.basename(path)
    for m in BAD_LOCATION.finditer(data):
        text = m.group(0).decode()
        # a path of the machine that built it (debug info, assert strings) is harmless in the data
        # sections but not as a library location
        if text.startswith(("/Users/",)):
            continue
        if is_third_party(rel):
            notes.append("%s: compiled for %s" % (rel, text))
        else:
            fail("%s: contains the location %s" % (rel, text))
        break
    if binary:
        for m in BARE_DYLIB.finditer(data):
            if (base, m.group(1).decode()) not in BARE_DYLIB_OK:
                fail("%s: opens %s by bare name (use an @rpath/ name)" % (rel, m.group(1).decode()))
    for m in DYLD_VAR.finditer(data):
        if (base, m.group(0)) not in DYLD_OK:
            fail("%s: mentions %s" % (rel, m.group(0).decode()))


def check_d3d_names(app):
    """The backend files are builtin DLLs renamed after their backend; Wine looks the builtin of
    such a file up by the name inside it (d3d11.dll), so an unsuffixed builtin of that name wins."""
    folder = os.path.join(app, "Contents/Resources/wine/lib/wine/x86_64-windows")
    for module in ("d3d11", "dxgi", "d3d10core"):
        plain = os.path.join(folder, module + ".dll")
        if not os.path.exists(plain):
            continue
        for backend in ("dxmt", "d3dm", "dxvk", "opengl", "openxr"):
            if os.path.exists(os.path.join(folder, "%s_%s.dll" % (module, backend))):
                fail("lib/wine/x86_64-windows/%s.dll hides %s_%s.dll: Wine loads it instead" % (module, module, backend))


def check_launcher(app):
    """Opening the application must behave like the WineHQ one: Terminal shows the welcome text of
    start/bin/winehelp with start/bin in PATH, and the application has an icon."""
    res = os.path.join(app, "Contents/Resources")
    for script in ("winehelp", "appdb"):
        path = os.path.join(res, "start/bin", script)
        if not os.access(path, os.X_OK):
            fail("Contents/Resources/start/bin/%s is missing or not executable" % script)
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        info = plistlib.load(f)
    icon = info.get("CFBundleIconFile")
    if not icon:
        fail("Info.plist has no CFBundleIconFile")
    elif not os.path.isfile(os.path.join(res, icon if icon.endswith(".icns") else icon + ".icns")):
        fail("the icon %s named by Info.plist is not in Contents/Resources" % icon)
    launcher = os.path.join(app, "Contents/MacOS", info.get("CFBundleExecutable", ""))
    if not os.path.isfile(launcher):
        fail("the launcher Contents/MacOS/%s is missing" % info.get("CFBundleExecutable"))
        return
    with open(launcher, "rb") as f:
        data = f.read()
    for needle in (b"winehelp --clear", b"start/bin"):
        if needle not in data:
            fail("the launcher does not mention %s" % needle.decode())


def main():
    app = sys.argv[1] if len(sys.argv) > 1 else None
    if not app or not os.path.isdir(app):
        print(__doc__)
        return 2
    count = 0
    for root, _, names in os.walk(app):
        for name in names:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, app)
            if os.path.islink(path):
                continue
            macho = is_macho(path)
            if macho:
                count += 1
                check_macho(path, rel)
            if macho or name.endswith((".sh", ".plist", ".command")) or (os.access(path, os.X_OK) and not is_pe(path)):
                if os.path.getsize(path) < 64 * 1024 * 1024:
                    check_bytes(path, rel, macho)
    check_d3d_names(app)
    check_launcher(app)
    for n in notes:
        print("note", n)
    for e in errors:
        print("FAIL", e)
    print("%d binaries checked, %d problems" % (count, len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
