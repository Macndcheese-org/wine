#!/usr/bin/env python3
"""Make a Wine install tree self-contained.

Copies every third-party dynamic library the tree needs into <prefix>/lib, points the
binaries at them with @rpath, and gives every binary run paths that lead there.  Nothing
is left that depends on Homebrew, on /usr/local or on DYLD_* variables.

The libraries Wine opens with dlopen() are the ones that are easy to miss, because no load
command names them: the build writes them into include/config.h as SONAME_LIB* leaf names.
Pass that file with --config-h; it is read for the names, and the unix libraries must have
been built with the names turned into @rpath/ names (see packaging/README.md).

Usage: bundle-dylibs.py --prefix DIR --search DIR [--search DIR ...] [--config-h FILE]
Environment: OTOOL, INSTALL_NAME_TOOL and CODESIGN override the tools (default: the Xcode ones).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

OTOOL = os.environ.get("OTOOL", "otool")
INSTALL_NAME_TOOL = os.environ.get("INSTALL_NAME_TOOL", "install_name_tool")
CODESIGN = os.environ.get("CODESIGN", "codesign")
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Apple/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        return f.read(4) in MACHO_MAGICS


def macho_files(prefix):
    # lib/external holds the GPTK files (D3DMetal.framework, libd3dshared.dylib): Apple's own
    # signature, run paths and libraries (libmetalirconverter inside the framework) stay as they are.
    external = os.path.join(prefix, "lib", "external") + os.sep
    for root, _, names in os.walk(prefix):
        for name in names:
            path = os.path.join(root, name)
            if path.startswith(external):
                continue
            if is_macho(path):
                yield path


def dependencies(path):
    """Install names the binary links against (not its own id)."""
    lines = run(OTOOL, "-L", path).splitlines()[1:]
    deps = [line.strip().split(" (")[0] for line in lines if line.strip()]
    if path.endswith((".dylib", ".so")) and deps and is_own_id(path, deps[0]):
        deps = deps[1:]
    return deps


def is_own_id(path, first):
    ids = run(OTOOL, "-D", path).splitlines()[1:]
    return bool(ids) and ids[0].strip() == first


def rpaths(path):
    out = run(OTOOL, "-l", path).splitlines()
    return [out[i + 2].strip().split(" (")[0].split("path ", 1)[1]
            for i, line in enumerate(out) if line.strip() == "cmd LC_RPATH"]


def signed(path):
    return subprocess.run((CODESIGN, "--verify", "--strict", path), capture_output=True).returncode == 0


def is_system(dep):
    return dep.startswith(SYSTEM_PREFIXES)


def find_library(name, search_dirs):
    for d in search_dirs:
        candidate = os.path.join(d, name)
        if os.path.exists(candidate):
            return os.path.realpath(candidate)
    return None


def resolve(dep, requester, search_dirs):
    """Real file behind an install name, or None when it can't be found."""
    if os.path.isabs(dep):
        return os.path.realpath(dep) if os.path.exists(dep) else find_library(os.path.basename(dep), search_dirs)
    base = os.path.basename(dep)
    if dep.startswith(("@loader_path/", "@executable_path/")):
        candidate = os.path.join(os.path.dirname(requester), dep.split("/", 1)[1])
        if os.path.exists(candidate):
            return os.path.realpath(candidate)
    return find_library(base, search_dirs)


def soname_seeds(config_h):
    names = []
    with open(config_h) as f:
        for line in f:
            m = re.match(r'#define SONAME_LIB\w+ "(?:@rpath/)?([^"]+\.dylib)"', line)
            if m:
                names.append(m.group(1))
    return names


def found_by_rpath(dep, requester):
    """True when an @rpath/ name is a file that one of the binary's own relative run paths leads to
    (Wine's .so files name each other, such as @rpath/ntdll.so, and rely on @loader_path)."""
    if not dep.startswith("@rpath/") or not os.path.isfile(requester):
        return False
    here = os.path.dirname(os.path.realpath(requester))
    for r in rpaths(requester):
        if r.startswith(("@loader_path", "@executable_path")):
            base = r.replace("@loader_path", here).replace("@executable_path", here)
            if os.path.exists(os.path.join(base, dep[len("@rpath/"):])):
                return True
    return False


def rpath_for(binary, libdir):
    rel = os.path.relpath(libdir, os.path.dirname(os.path.realpath(binary)))
    return "@loader_path/" + rel if rel != "." else "@loader_path"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--search", action="append", default=[], help="directory to find libraries in")
    ap.add_argument("--config-h")
    ap.add_argument("--no-sign", action="store_true")
    args = ap.parse_args()

    prefix = os.path.realpath(args.prefix)
    libdir = os.path.join(prefix, "lib")
    os.makedirs(libdir, exist_ok=True)

    binaries = list(macho_files(prefix))
    copied = {}     # real source file -> bundled name
    missing = []
    queue = []

    def want(dep, requester):
        if is_system(dep) or found_by_rpath(dep, requester):
            return
        src = resolve(dep, requester, args.search)
        if not src:
            if not dep.startswith("@rpath/") or not find_library(os.path.basename(dep), [libdir]):
                missing.append((dep, requester))
            return
        if src.startswith(libdir + os.sep) or src.startswith(prefix + os.sep):
            return
        if src not in copied:
            # keep the name other binaries ask for, plus the real file name
            shutil.copy2(src, os.path.join(libdir, os.path.basename(src)))
            os.chmod(os.path.join(libdir, os.path.basename(src)), 0o755)
            copied[src] = os.path.basename(src)
            queue.append(os.path.join(libdir, os.path.basename(src)))
        alias = os.path.join(libdir, os.path.basename(dep))
        if os.path.basename(dep) != copied[src] and not os.path.lexists(alias):
            os.symlink(copied[src], alias)

    for b in binaries:
        for dep in dependencies(b):
            want(dep, b)
    if args.config_h:
        for name in soname_seeds(args.config_h):
            src = find_library(name, args.search)
            if src:
                want(src, os.path.join(libdir, "seed"))
                alias = os.path.join(libdir, name)
                if not os.path.lexists(alias) and os.path.basename(src) != name:
                    os.symlink(os.path.basename(src), alias)
            else:
                print("note: SONAME_ library %s is not in the search paths; the feature stays off" % name)
    while queue:
        lib = queue.pop()
        for dep in dependencies(lib):
            want(dep, lib)

    # Rewrite every binary, bundled libraries included.
    everything = list(macho_files(prefix))
    for b in everything:
        changes = []
        for dep in dependencies(b):
            if is_system(dep) or dep.startswith("@rpath/"):
                continue
            changes += ["-change", dep, "@rpath/" + os.path.basename(dep)]
        if b.startswith(libdir + os.sep) and b.endswith(".dylib") and os.path.dirname(b) == libdir:
            changes += ["-id", "@rpath/" + os.path.basename(b)]
        wanted = rpath_for(b, libdir)
        have = rpaths(b)
        for old in dict.fromkeys(have):                    # nothing absolute may stay
            if not old.startswith(("@loader_path", "@executable_path")):
                changes += ["-delete_rpath", old]
        # A binary that links nothing but system libraries needs no run path: libRuntimeRosettax87 is a
        # static executable with no room for a new load command.
        if wanted not in have and any(not is_system(d) for d in dependencies(b)):
            changes += ["-add_rpath", wanted]
        if changes:
            try:
                run(INSTALL_NAME_TOOL, *changes, b)
            except subprocess.CalledProcessError as e:
                sys.exit("install_name_tool failed on %s: %s" % (b, e.stderr.strip()))
        # What the linker or install left unsigned or invalid is signed as well, except
        # libRuntimeRosettax87, which runtime_loader injects as it is.
        if not args.no_sign and (changes or (os.path.basename(b) != "libRuntimeRosettax87" and not signed(b))):
            run(CODESIGN, "--force", "--sign", "-", b)

    for dep, requester in missing:
        print("error: %s (needed by %s) not found" % (dep, os.path.relpath(requester, prefix)), file=sys.stderr)
    print("bundled %d libraries into %s" % (len(copied), libdir))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
