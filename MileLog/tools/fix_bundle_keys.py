#!/usr/bin/env python3
"""Add the CFBundle* identity keys an Info.plist needs to be installable.

A target with GENERATE_INFOPLIST_FILE = NO gets nothing injected from build
settings, so its Info.plist has to carry the identity keys itself. Xcode 16
projects normally run with generation ON and no Info.plist at all, so a plist
written by hand for such a project reliably lacks them — and the app then
builds and signs fine but fails to install with

    Failed to get bundle ID ... Missing bundle ID.        (simulator)
    The item at MileLog.app is not a valid bundle.        (device)

Values referencing $(...) are build settings; Xcode substitutes them while
processing the file. Uses plistlib rather than PlistBuddy so no shell
quoting is involved — "$(PRODUCT_BUNDLE_IDENTIFIER)" inside double quotes
is command substitution to the shell, and single quotes collide with
PlistBuddy's own parsing.

Usage:
    python3 tools/fix_bundle_keys.py [path/to/Info.plist]

Only adds what is missing; never changes a key that is already there.
Writes a .bak first.
"""

import os
import plistlib
import signal
import shutil
import sys

# Keys every installable iOS app bundle needs, and why the value is what it
# is. $(...) entries stay in sync with the build settings; the rest are
# fixed because they never vary for a plain iOS app.
REQUIRED = [
    ("CFBundleIdentifier", "$(PRODUCT_BUNDLE_IDENTIFIER)",
     "the missing key that blocks installation"),
    ("CFBundleExecutable", "$(EXECUTABLE_NAME)",
     "which binary inside the bundle to launch"),
    ("CFBundleName", "$(PRODUCT_NAME)", "short display name"),
    ("CFBundlePackageType", "APPL", "APPL marks it an application"),
    ("CFBundleInfoDictionaryVersion", "6.0", "plist format version"),
    ("CFBundleDevelopmentRegion", "en", "fallback localization"),
    ("CFBundleVersion", "1", "build number"),
    ("CFBundleShortVersionString", "1.0", "marketing version"),
    ("LSRequiresIPhoneOS", True, "iOS-only application"),
    ("UILaunchScreen", {},
     "without it iOS runs the app letterboxed at a smaller size"),
    ("UISupportedInterfaceOrientations", ["UIInterfaceOrientationPortrait"],
     "portrait only, matching the layouts"),
]


def main(argv):
    # Piping into head closes the pipe early; die quietly rather than
    # printing a traceback at someone who just wanted less output.
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError):
        pass
    path = argv[1] if len(argv) > 1 else "MileLog/Info.plist"
    if not os.path.isfile(path):
        sys.stderr.write("no such file: %s\n" % path)
        return 2

    with open(path, "rb") as f:
        plist = plistlib.load(f)

    added, present = [], []
    for key, value, why in REQUIRED:
        if key in plist:
            present.append(key)
        else:
            plist[key] = value
            added.append((key, value, why))

    print("%s\n" % os.path.abspath(path))
    if present:
        print("Already present (left untouched): %s\n" % ", ".join(sorted(present)))
    if not added:
        print("Nothing to add — every required key is already there.")
        print("If the install still fails, the cause is elsewhere.")
        return 0

    shutil.copy2(path, path + ".bak")
    with open(path, "wb") as f:
        plistlib.dump(plist, f, sort_keys=True)

    print("Added %d key(s):" % len(added))
    for key, value, why in added:
        print("  %-32s = %-32s  %s" % (key, repr(value), why))

    print("\nFull key list now:")
    for key in sorted(plist):
        print("  %s" % key)
    print("\nBackup: %s.bak" % path)
    print("\nNext: Xcode > Product > Clean Build Folder, then Run.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
