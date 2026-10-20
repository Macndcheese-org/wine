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
  * the bundle holds an unsigned or invalidly signed binary.

Usage: verify-app.py "MNC Wine.app"
Environment: OTOOL and CODESIGN override the tools.
"""

import os
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

# Strings in Wine's own code that are not locations the bundle depends on.
BARE_DYLIB_OK = set()
DYLD_OK = {                      # ntdll.so points DYLD_LIBRARY_PATH at the build tree, only in a build tree
    ("ntdll.so", b"DYLD_LIBRARY_PATH"),
    ("ntdll.so", b"DYLD_INSERT_LIBRARIES"),
    ("ntdll.so", b"ROSETTA_X87_SAVED_DYLD_INSERT_LIBRARIES"),
}

errors = []


def fail(msg):
    errors.append(msg)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True)


def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        return f.read(4) in MAGICS


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
    for r in rpaths:
        if not r.startswith(("@loader_path", "@executable_path")):
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
        if run(CODESIGN, "--verify", "--strict", path).returncode:
            fail("%s: signature missing or invalid" % rel)


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
        fail("%s: contains the location %s" % (rel, text))
        break
    if binary:
        for m in BARE_DYLIB.finditer(data):
            if m.group(1).decode() not in BARE_DYLIB_OK:
                fail("%s: opens %s by bare name (use an @rpath/ name)" % (rel, m.group(1).decode()))
    for m in DYLD_VAR.finditer(data):
        if (base, m.group(0)) not in DYLD_OK:
            fail("%s: mentions %s" % (rel, m.group(0).decode()))


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
            if macho or name.endswith((".sh", ".plist", ".command")) or os.access(path, os.X_OK):
                if os.path.getsize(path) < 64 * 1024 * 1024:
                    check_bytes(path, rel, macho)
    for e in errors:
        print("FAIL", e)
    print("%d binaries checked, %d problems" % (count, len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
