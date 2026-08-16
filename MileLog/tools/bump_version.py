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

It also writes MARKETING_VERSION and CURRENT_PROJECT_VERSION into the
Xcode project when one is found. Those two are what a target with
GENERATE_INFOPLIST_FILE = YES actually ships — Xcode injects them and
overwrites whatever the plist file says, so bumping only the plist leaves
the app reporting Xcode's defaults, 1.0 (1). Writing both means the
version is right whichever way the target is configured, and the two
cannot drift apart.

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
DEFAULT_PROJECT = "MileLog.xcodeproj/project.pbxproj"


def sync_project(path, version, build):
    """Set MARKETING_VERSION / CURRENT_PROJECT_VERSION on every build config
    that carries a PRODUCT_BUNDLE_IDENTIFIER (i.e. the app target's, not the
    project-level ones). Returns a short report, or None if there is no
    project file to touch."""
    import re
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    wanted = {"MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": str(build)}
    changed, added = 0, 0
    lines = text.splitlines(True)
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        if "buildSettings = {" not in line:
            i += 1
            continue
        # Collect this buildSettings block.
        block, j = [], i + 1
        while j < len(lines) and lines[j].strip() != "};":
            block.append(lines[j])
            j += 1
        body = "".join(block)
        if "PRODUCT_BUNDLE_IDENTIFIER" not in body:
            out.extend(block)
            i = j
            continue
        indent = re.match(r"\s*", block[0]).group(0) if block else "\t\t\t\t"
        for key, value in wanted.items():
            pattern = re.compile(r"^(\s*)%s\s*=\s*[^;]*;\s*$" % key, re.MULTILINE)
            if pattern.search(body):
                body, n = pattern.subn(r"\g<1>%s = %s;" % (key, value), body)
                changed += n
            else:
                body = indent + "%s = %s;\n" % (key, value) + body
                added += 1
        out.append(body)
        i = j
    if not changed and not added:
        return None
    shutil.copy2(path, path + ".bak")
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(out))
    return "project: %d setting(s) updated, %d added" % (changed, added)


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
    report = sync_project(DEFAULT_PROJECT, version, next_build)
    if report:
        print(report)
    elif os.path.isfile(DEFAULT_PROJECT):
        print("project: no target build config found to update")
    else:
        print("project: %s not found, plist only" % DEFAULT_PROJECT)

    print("\nSettings > About in the app will show: %s (%d)" % (version, next_build))
    print("Backup: %s.bak" % plist_path)
    print("\nNow Clean Build Folder and Run, so the number matches what installs.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
