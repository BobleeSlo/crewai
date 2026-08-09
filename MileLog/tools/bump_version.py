#!/usr/bin/env python3
"""Bump the app's version and build number in Info.plist.

With GENERATE_INFOPLIST_FILE = NO the Version and Build fields on Xcode's
General tab edit MARKETING_VERSION / CURRENT_PROJECT_VERSION, which nothing
in the target reads — typing a new number there silently has no effect. The
literals in Info.plist are what ship, so this writes them directly.

Run it before every build you intend to install. The build number then
identifies exactly which code produced a given Detection Log, which is the
whole point: "no changes, still broken" and "I am running last week's build"
look identical from the outside otherwise.

Usage:
    python3 tools/bump_version.py                  # build +1
    python3 tools/bump_version.py --version 1.2    # set version, build +1
    python3 tools/bump_version.py --show           # print, change nothing

The build number only ever increases — App Store Connect rejects an upload
whose build is not higher than the last one for the same version.
"""

import os
import plistlib
import shutil
import sys

DEFAULT_PLIST = "MileLog/Info.plist"


def main(argv):
    args = argv[1:]
    show_only = "--show" in args
    plist_path = DEFAULT_PLIST
    new_version = None

    i = 0
    while i < len(args):
        if args[i] == "--version":
            if i + 1 >= len(args):
                sys.stderr.write("--version needs a value, e.g. --version 1.2\n")
                return 2
            new_version = args[i + 1]
            i += 2
        elif args[i] == "--show":
            i += 1
        elif args[i].startswith("-"):
            sys.stderr.write("unknown option: %s\n" % args[i])
            return 2
        else:
            plist_path = args[i]
            i += 1

    if not os.path.isfile(plist_path):
        sys.stderr.write("no such file: %s\n"
                         "pass the path explicitly if it is not %s\n"
                         % (plist_path, DEFAULT_PLIST))
        return 2

    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)

    old_version = plist.get("CFBundleShortVersionString", "1.0")
    old_build_raw = plist.get("CFBundleVersion", "0")

    if show_only:
        print("%s (%s)" % (old_version, old_build_raw))
        return 0

    try:
        next_build = int(str(old_build_raw)) + 1
    except ValueError:
        sys.stderr.write(
            "CFBundleVersion is %r, which is not a whole number.\n"
            "Set it to an integer by hand, then re-run.\n" % old_build_raw)
        return 1

    version = new_version if new_version else old_version

    shutil.copy2(plist_path, plist_path + ".bak")
    plist["CFBundleShortVersionString"] = version
    plist["CFBundleVersion"] = str(next_build)
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f, sort_keys=True)

    print("%s (%s)  ->  %s (%d)"
          % (old_version, old_build_raw, version, next_build))
    print("\nSettings > About in the app will show: %s (%d)" % (version, next_build))
    print("Backup: %s.bak" % plist_path)
    print("\nNow Clean Build Folder and Run, so the number matches what installs.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
