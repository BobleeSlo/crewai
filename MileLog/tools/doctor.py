#!/usr/bin/env python3
"""Diagnose (and optionally repair) an Xcode project that fails with
'Multiple commands produce ... .stringsdata'.

That error means one target's Compile Sources phase feeds two inputs whose
file names collide, because the per-file .stringsdata output is named after
the basename alone. There are two distinct causes and they need different
fixes, so this reports which one you have before changing anything:

  A. the SAME file on disk is listed twice   -> remove the extra entry
  B. TWO different files share a basename    -> one is a stray copy; the
     duplicate directory has to go, and the project can't guess which

It resolves each entry to its real path by walking the PBXGroup tree, so it
can tell those apart, and it checks which paths actually exist on disk.

Usage:
    python3 tools/doctor.py MileLog.xcodeproj/project.pbxproj
    python3 tools/doctor.py --fix MileLog.xcodeproj/project.pbxproj

Without --fix nothing is written. With --fix it removes case A duplicates
only, and still just reports case B.
"""

import os
import re
import shutil
import subprocess
import sys

HEX = r"[0-9A-Fa-f]{24}"

# Object headers are matched a line at a time. Cross-line regex is a trap
# here: a /* comment */ pattern with DOTALL will happily span from one
# section into the next and pair the wrong id with the wrong body.
OBJ_HEADER_RE = re.compile(
    r"^(\s*)(%s)\b(?:\s*/\*.*?\*/)?\s*=\s*\{(.*)$" % HEX
)
BUILD_FILE_RE = re.compile(
    r"^\s*(%s)\s*(?:/\*.*?\*/\s*)?=\s*\{isa\s*=\s*PBXBuildFile;.*?fileRef\s*=\s*(%s)\b"
    % (HEX, HEX),
    re.MULTILINE,
)
SOURCES_PHASE_RE = re.compile(
    r"(\{\s*isa\s*=\s*PBXSourcesBuildPhase;.*?files\s*=\s*\()(.*?)(\)\s*;)",
    re.DOTALL,
)
ENTRY_RE = re.compile(r"^([ \t]*)(%s)(\s*/\*(.*?)\*/)?\s*,\s*$" % HEX)
ATTR_RE = re.compile(r"\b(path|name|sourceTree)\s*=\s*(\"[^\"]*\"|[^;]+);")
CHILDREN_RE = re.compile(r"children\s*=\s*\((.*?)\)\s*;", re.DOTALL)


def attrs_of(body):
    return dict(
        (m.group(1), m.group(2).strip().strip('"'))
        for m in ATTR_RE.finditer(body)
    )


def iter_objects(text):
    """Yield (obj_id, isa, body) for every top-level object in the archive.

    Walks lines rather than matching across them: an object starts at a line
    of the form `<id> /* comment */ = {` and ends either on that same line
    (PBXBuildFile, PBXFileReference) or at the first line that is exactly the
    opening indentation followed by `};` (PBXGroup and friends).
    """
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        match = OBJ_HEADER_RE.match(lines[index])
        if not match:
            index += 1
            continue
        indent, obj_id, remainder = match.groups()
        if remainder.rstrip().endswith("};"):
            body = remainder.rstrip()[:-2]
            index += 1
        else:
            collected, closer = [remainder], indent + "};"
            index += 1
            while index < len(lines) and lines[index].rstrip() != closer:
                collected.append(lines[index])
                index += 1
            index += 1
            body = "\n".join(collected)
        isa = re.search(r"\bisa\s*=\s*(\w+)\s*;", body)
        yield obj_id, (isa.group(1) if isa else ""), body


def build_index(text):
    """Return (path_of_ref, name_of_ref) with paths relative to the project dir."""
    refs, groups, parent = {}, {}, {}

    for obj_id, isa, body in iter_objects(text):
        if isa == "PBXFileReference":
            refs[obj_id] = attrs_of(body)
        elif isa in ("PBXGroup", "PBXVariantGroup"):
            groups[obj_id] = attrs_of(body)
            children = CHILDREN_RE.search(body)
            if children:
                for child in re.findall(HEX, children.group(1)):
                    parent[child] = obj_id

    def full_path(node_id):
        parts, seen = [], set()
        current = node_id
        while current and current not in seen:
            seen.add(current)
            info = refs.get(current) or groups.get(current) or {}
            segment = info.get("path")
            if segment:
                parts.append(segment)
            if info.get("sourceTree") in ("SOURCE_ROOT", "<absolute>"):
                break
            current = parent.get(current)
        return os.path.join(*reversed(parts)) if parts else ""

    path_of = {rid: full_path(rid) for rid in refs}
    name_of = {
        rid: (info.get("path") or info.get("name") or rid)
        for rid, info in refs.items()
    }
    return path_of, name_of


def main(argv):
    do_fix = "--fix" in argv[1:]
    args = [a for a in argv[1:] if not a.startswith("-")]
    if len(args) != 1:
        sys.stderr.write("usage: doctor.py [--fix] <project.pbxproj>\n")
        return 2
    pbx = args[0]
    if not os.path.isfile(pbx):
        sys.stderr.write("not a file: %s\n" % pbx)
        return 2

    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(pbx))) or "."

    print("=" * 68)
    print("MileLog project doctor")
    print("=" * 68)

    try:
        running = subprocess.call(
            ["pgrep", "-x", "Xcode"], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL) == 0
    except OSError:
        running = None
    if running is True:
        print("\n!! Xcode is RUNNING. It holds the project in memory and will")
        print("!! overwrite edits made here. Quit Xcode, then run this again.")
    elif running is False:
        print("\nXcode is not running. Safe to edit.")

    print("\nProject: %s" % os.path.abspath(pbx))
    print("Root:    %s" % project_dir)

    with open(pbx, "r", encoding="utf-8") as f:
        text = f.read()

    path_of, name_of = build_index(text)
    ref_of_build = {m.group(1): m.group(2) for m in BUILD_FILE_RE.finditer(text)}
    phases = list(SOURCES_PHASE_RE.finditer(text))

    entries = []      # (build_id, ref_id, relpath, basename, exists)
    for phase in phases:
        for line in phase.group(2).splitlines():
            entry = ENTRY_RE.match(line)
            if not entry:
                continue
            build_id = entry.group(2)
            ref_id = ref_of_build.get(build_id, "")
            rel = path_of.get(ref_id, "")
            base = os.path.basename(rel or name_of.get(ref_id, build_id))
            exists = os.path.isfile(os.path.join(project_dir, rel)) if rel else False
            entries.append((build_id, ref_id, rel, base.lower(), exists))

    print("\n-- Compile Sources -------------------------------------------")
    print("  build phases:      %d" % len(phases))
    print("  entries:           %d" % len(entries))
    print("  distinct basenames:%d" % len({e[3] for e in entries}))
    print("  entries whose file is missing on disk: %d"
          % sum(1 for e in entries if not e[4]))

    by_base = {}
    for e in entries:
        by_base.setdefault(e[3], []).append(e)
    collisions = {b: v for b, v in by_base.items() if len(v) > 1}

    same_file, different_files = [], []
    for base, group in sorted(collisions.items()):
        paths = {e[2] for e in group}
        (same_file if len(paths) == 1 else different_files).append((base, group))

    if not collisions:
        print("\n  No basename collisions. This project is NOT the cause of")
        print("  the 'Multiple commands produce' errors.")
    else:
        print("\n  %d colliding basenames (%d same-file, %d different-file)"
              % (len(collisions), len(same_file), len(different_files)))

    if same_file:
        print("\n-- CASE A: same file listed more than once --------------------")
        for base, group in same_file:
            print("  %s  x%d   %s" % (base, len(group), group[0][2]))
        print("  Fixable automatically. Re-run with --fix.")

    if different_files:
        print("\n-- CASE B: different files sharing a name ---------------------")
        for base, group in different_files:
            print("  %s" % base)
            for e in group:
                print("      %s   %s"
                      % ("ok     " if e[4] else "MISSING", e[2] or "(unresolved)"))
        print("\n  Two real files cannot both compile into this target. Delete or")
        print("  remove the stray copy — usually the one marked MISSING, or the")
        print("  one outside the canonical source folder. Not fixed automatically.")

    print("\n-- Duplicate .swift basenames on disk -------------------------")
    on_disk = {}
    for root, dirs, files in os.walk(project_dir):
        dirs[:] = [d for d in dirs
                   if d not in (".git", "build", "DerivedData")
                   and not d.endswith(".xcodeproj")]
        for name in files:
            if name.endswith(".swift"):
                rel = os.path.relpath(os.path.join(root, name), project_dir)
                on_disk.setdefault(name.lower(), []).append(rel)
    dupes_on_disk = {k: v for k, v in on_disk.items() if len(v) > 1}
    if dupes_on_disk:
        print("  %d file names exist in more than one place:" % len(dupes_on_disk))
        for name in sorted(dupes_on_disk):
            print("    %s" % name)
            for rel in sorted(dupes_on_disk[name]):
                print("        %s" % rel)
        print("\n  A second copy of a source folder is the usual cause of CASE B.")
    else:
        print("  None — every .swift basename is unique on disk (%d files)."
              % len(on_disk))

    if not do_fix:
        print("\n(read-only; nothing written — add --fix to remove CASE A dupes)")
        return 0
    if not same_file:
        print("\n--fix: no CASE A duplicates to remove. Nothing written.")
        return 0
    if running:
        print("\n--fix refused: quit Xcode first, or it will undo the change.")
        return 1

    remove_ids = set()
    for _, group in same_file:
        for e in group[1:]:
            remove_ids.add(e[0])

    def strip_phase(match):
        head, body, tail = match.group(1), match.group(2), match.group(3)
        kept = [line for line in body.splitlines(True)
                if not (ENTRY_RE.match(line.rstrip("\n"))
                        and ENTRY_RE.match(line.rstrip("\n")).group(2) in remove_ids)]
        return head + "".join(kept) + tail

    new_text = SOURCES_PHASE_RE.sub(strip_phase, text)
    new_text = "".join(
        line for line in new_text.splitlines(True)
        if not ("isa = PBXBuildFile;" in line and line.lstrip()[:24] in remove_ids)
    )

    orphans = {ref_of_build[b] for b in remove_ids if b in ref_of_build}
    orphans -= {m.group(2) for m in BUILD_FILE_RE.finditer(new_text)}
    if orphans:
        new_text = "".join(
            line for line in new_text.splitlines(True)
            if not (line.lstrip()[:24] in orphans
                    and ("isa = PBXFileReference;" in line
                         or re.match(r"^%s\s*/\*.*\*/,\s*$" % HEX, line.lstrip())))
        )

    shutil.copy2(pbx, pbx + ".bak")
    with open(pbx, "w", encoding="utf-8") as f:
        f.write(new_text)
    print("\n--fix: removed %d duplicate entries and %d orphaned references."
          % (len(remove_ids), len(orphans)))
    print("Backup: %s.bak" % pbx)
    print("Reopen Xcode, then Product > Clean Build Folder.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
