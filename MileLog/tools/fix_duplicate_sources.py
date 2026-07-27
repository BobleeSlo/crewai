#!/usr/bin/env python3
"""Remove duplicate entries from an Xcode target's Compile Sources phase.

Adding files that are already members of a target makes Xcode append a second
PBXBuildFile for the same PBXFileReference. The build then emits

    error: Multiple commands produce '.../Foo.stringsdata'

once per doubled Swift file. This script keeps the first build-file entry for
each file reference in every PBXSourcesBuildPhase, drops the rest, and deletes
the PBXBuildFile objects that are left orphaned.

Usage:
    python3 tools/fix_duplicate_sources.py MileLog.xcodeproj/project.pbxproj

Writes a .bak beside the file before touching it. Prints what it removed and
exits 0 even when there was nothing to do.
"""

import os
import re
import shutil
import sys

BUILD_FILE_RE = re.compile(
    r"^\s*([0-9A-F]{24})\s*/\*.*?\*/\s*=\s*\{isa\s*=\s*PBXBuildFile;"
    r".*?fileRef\s*=\s*([0-9A-F]{24})\b",
    re.MULTILINE,
)

SOURCES_PHASE_RE = re.compile(
    r"(\{\s*isa\s*=\s*PBXSourcesBuildPhase;.*?files\s*=\s*\()(.*?)(\)\s*;)",
    re.DOTALL,
)

ENTRY_RE = re.compile(r"^([ \t]*)([0-9A-F]{24})(\s*/\*(.*?)\*/)?\s*,\s*$")


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: fix_duplicate_sources.py <project.pbxproj>\n")
        return 2
    path = argv[1]
    if not os.path.isfile(path):
        sys.stderr.write("not a file: %s\n" % path)
        return 2

    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    # buildFileID -> fileRefID
    ref_of = {m.group(1): m.group(2) for m in BUILD_FILE_RE.finditer(text)}

    removed = []          # (buildFileID, display name)
    removed_ids = set()

    def dedupe_phase(match):
        head, body, tail = match.group(1), match.group(2), match.group(3)
        seen_refs = set()
        kept_lines = []
        for line in body.splitlines(True):
            entry = ENTRY_RE.match(line.rstrip("\n"))
            if not entry:
                kept_lines.append(line)
                continue
            build_id = entry.group(2)
            name = (entry.group(4) or build_id).strip()
            ref = ref_of.get(build_id)
            key = ref if ref else ("name:" + name)
            if key in seen_refs:
                removed.append((build_id, name))
                removed_ids.add(build_id)
                continue
            seen_refs.add(key)
            kept_lines.append(line)
        return head + "".join(kept_lines) + tail

    new_text = SOURCES_PHASE_RE.sub(dedupe_phase, text)

    # Drop the PBXBuildFile objects nobody references any more.
    if removed_ids:
        kept = []
        for line in new_text.splitlines(True):
            stripped = line.lstrip()
            if (
                "isa = PBXBuildFile;" in line
                and stripped[:24] in removed_ids
            ):
                continue
            kept.append(line)
        new_text = "".join(kept)

    if not removed:
        print("No duplicate Compile Sources entries found. Nothing changed.")
        return 0

    backup = path + ".bak"
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)

    print("Removed %d duplicate Compile Sources entries:" % len(removed))
    for _, name in sorted(removed, key=lambda pair: pair[1]):
        print("  - %s" % name)
    print("\nBackup written to %s" % backup)
    print("Reopen the project in Xcode, then Product > Clean Build Folder.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
