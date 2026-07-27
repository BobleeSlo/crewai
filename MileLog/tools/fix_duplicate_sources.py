#!/usr/bin/env python3
"""Diagnose and remove duplicate Compile Sources entries in an Xcode project.

Adding files that are already target members makes Xcode add a SECOND
PBXFileReference for the same file on disk, plus a second PBXBuildFile
pointing at it. The build then fails with one

    error: Multiple commands produce '.../Foo.stringsdata'

per doubled file. Because the two entries have different file-reference IDs,
de-duplicating by reference ID misses them entirely — this script keys on the
file's name on disk instead, and looks across every PBXSourcesBuildPhase in
the project rather than one phase at a time.

It always prints a diagnosis first, so a run that changes nothing still tells
you what is actually in the file.

Usage:
    python3 tools/fix_duplicate_sources.py MileLog.xcodeproj/project.pbxproj
    python3 tools/fix_duplicate_sources.py --dry-run MileLog.xcodeproj/project.pbxproj

Writes a .bak beside the file before changing anything.
"""

import os
import re
import shutil
import sys

FILE_REF_RE = re.compile(
    r"^\s*([0-9A-Fa-f]{24})\s*/\*.*?\*/\s*=\s*\{isa\s*=\s*PBXFileReference;(.*?)\};",
    re.MULTILINE,
)

BUILD_FILE_RE = re.compile(
    r"^\s*([0-9A-Fa-f]{24})\s*/\*.*?\*/\s*=\s*\{isa\s*=\s*PBXBuildFile;"
    r".*?fileRef\s*=\s*([0-9A-Fa-f]{24})\b",
    re.MULTILINE,
)

SOURCES_PHASE_RE = re.compile(
    r"(\{\s*isa\s*=\s*PBXSourcesBuildPhase;.*?files\s*=\s*\()(.*?)(\)\s*;)",
    re.DOTALL,
)

ENTRY_RE = re.compile(
    r"^([ \t]*)([0-9A-Fa-f]{24})(\s*/\*(.*?)\*/)?\s*,\s*$"
)

ATTR_RE = re.compile(r"\b(path|name)\s*=\s*(\"[^\"]*\"|[^;]+);")


def parse_file_refs(text):
    """fileRefID -> basename on disk (lowercased)."""
    out = {}
    for match in FILE_REF_RE.finditer(text):
        attrs = dict(
            (m.group(1), m.group(2).strip().strip('"'))
            for m in ATTR_RE.finditer(match.group(2))
        )
        value = attrs.get("path") or attrs.get("name")
        if value:
            out[match.group(1)] = os.path.basename(value).lower()
    return out


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("-")]
    dry_run = "--dry-run" in argv[1:]
    if len(args) != 1:
        sys.stderr.write(
            "usage: fix_duplicate_sources.py [--dry-run] <project.pbxproj>\n"
        )
        return 2
    path = args[0]
    if not os.path.isfile(path):
        sys.stderr.write("not a file: %s\n" % path)
        return 2

    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    name_of_ref = parse_file_refs(text)
    ref_of_build = {m.group(1): m.group(2) for m in BUILD_FILE_RE.finditer(text)}
    phases = list(SOURCES_PHASE_RE.finditer(text))

    # ---- diagnosis -----------------------------------------------------
    def key_for(build_id, comment):
        ref = ref_of_build.get(build_id)
        if ref and ref in name_of_ref:
            return name_of_ref[ref]
        if comment:
            return os.path.basename(
                comment.strip().split(" in ")[0]
            ).lower()
        return build_id

    all_entries = []          # (phase_index, build_id, key)
    for phase_index, phase in enumerate(phases):
        for line in phase.group(2).splitlines():
            entry = ENTRY_RE.match(line)
            if entry:
                build_id = entry.group(2)
                all_entries.append(
                    (phase_index, build_id, key_for(build_id, entry.group(4)))
                )

    counts = {}
    for _, _, key in all_entries:
        counts[key] = counts.get(key, 0) + 1
    dupes = sorted(k for k, n in counts.items() if n > 1)

    print("Diagnosis")
    print("  file: %s" % path)
    print("  PBXSourcesBuildPhase sections: %d" % len(phases))
    print("  compile-sources entries:       %d" % len(all_entries))
    print("  distinct files:                %d" % len(counts))
    print("  PBXFileReference objects:      %d" % len(name_of_ref))
    print("  files listed more than once:   %d" % len(dupes))
    if dupes:
        for key in dupes:
            print("      %-34s x%d" % (key, counts[key]))
    print("")

    if not dupes:
        print("Nothing to remove. If the build still reports "
              "'Multiple commands produce', send me this diagnosis block —")
        print("the cause is somewhere other than a doubled Compile Sources entry.")
        return 0

    # ---- removal -------------------------------------------------------
    removed = []
    removed_ids = set()
    seen = set()
    for _, build_id, key in all_entries:
        if key in seen:
            removed.append((build_id, key))
            removed_ids.add(build_id)
        else:
            seen.add(key)

    def strip_phase(match):
        head, body, tail = match.group(1), match.group(2), match.group(3)
        kept = []
        for line in body.splitlines(True):
            entry = ENTRY_RE.match(line.rstrip("\n"))
            if entry and entry.group(2) in removed_ids:
                continue
            kept.append(line)
        return head + "".join(kept) + tail

    new_text = SOURCES_PHASE_RE.sub(strip_phase, text)

    # Build-file objects nobody references any more.
    kept_lines = []
    for line in new_text.splitlines(True):
        if "isa = PBXBuildFile;" in line and line.lstrip()[:24] in removed_ids:
            continue
        kept_lines.append(line)
    new_text = "".join(kept_lines)

    # File references orphaned by the above: only those we just unhooked, and
    # only if no surviving build file still points at them. Leaves refs that
    # were never in a build phase (Info.plist and friends) alone.
    candidates = {
        ref_of_build[b] for b in removed_ids if b in ref_of_build
    }
    still_used = set()
    for match in BUILD_FILE_RE.finditer(new_text):
        still_used.add(match.group(2))
    orphan_refs = candidates - still_used

    if orphan_refs:
        kept_lines = []
        for line in new_text.splitlines(True):
            stripped = line.lstrip()
            ref_id = stripped[:24]
            if ref_id in orphan_refs and (
                "isa = PBXFileReference;" in line          # the definition
                or re.match(r"^[0-9A-Fa-f]{24}\s*/\*.*\*/,\s*$", stripped)
            ):
                continue                                   # group membership
            kept_lines.append(line)
        new_text = "".join(kept_lines)

    if dry_run:
        print("--dry-run: would remove %d entries and %d orphaned file "
              "references. Nothing written." % (len(removed), len(orphan_refs)))
        return 0

    backup = path + ".bak"
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)

    print("Removed %d duplicate Compile Sources entries:" % len(removed))
    for _, key in sorted(removed, key=lambda pair: pair[1]):
        print("  - %s" % key)
    print("Removed %d orphaned file references." % len(orphan_refs))
    print("")
    print("Backup: %s" % backup)
    print("Reopen Xcode, then Product > Clean Build Folder before building.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
