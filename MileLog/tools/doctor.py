#!/usr/bin/env python3
"""Diagnose an Xcode project that fails with 'Multiple commands produce
... .stringsdata'.

That error means one target compiles two inputs whose file names collide,
because the per-file .stringsdata output is named after the basename alone.

Scanning Compile Sources alone is not enough. Xcode 16 targets can include a
whole directory through a PBXFileSystemSynchronizedRootGroup: those files are
compiled but never appear as Compile Sources entries. A target that has a
synchronized folder AND explicit entries for a second copy of the same files
collides on every one of them while Compile Sources looks perfectly clean.

So this computes each target's EFFECTIVE source list — explicit entries plus
the contents of its synchronized folders, minus membership exceptions — and
looks for collisions there. It also compares duplicate copies on disk by
content, size and date, so you can tell which one to keep.

Usage:
    python3 tools/doctor.py MileLog.xcodeproj/project.pbxproj
    python3 tools/doctor.py --fix MileLog.xcodeproj/project.pbxproj

Without --fix nothing is written.
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

HEX = r"[0-9A-Fa-f]{24}"

# Object headers are read a line at a time. Cross-line regex is a trap here:
# a /* comment */ pattern with DOTALL spans from one section into the next
# and pairs the wrong id with the wrong body.
OBJ_HEADER_RE = re.compile(r"^(\s*)(%s)\b(?:\s*/\*.*?\*/)?\s*=\s*\{(.*)$" % HEX)
ENTRY_RE = re.compile(r"^([ \t]*)(%s)(\s*/\*(.*?)\*/)?\s*,\s*$" % HEX)
ATTR_RE = re.compile(r"\b(path|name|sourceTree|productType|isa)\s*=\s*"
                     r"(\"[^\"]*\"|[^;]+);")
LIST_RE = r"%s\s*=\s*\((.*?)\)\s*;"


def attrs_of(body):
    return dict((m.group(1), m.group(2).strip().strip('"'))
                for m in ATTR_RE.finditer(body))


def list_of(body, key):
    match = re.search(LIST_RE % key, body, re.DOTALL)
    return re.findall(HEX, match.group(1)) if match else []


def strings_of(body, key):
    match = re.search(LIST_RE % key, body, re.DOTALL)
    if not match:
        return []
    return [s.strip().strip('"').strip(",").strip()
            for s in match.group(1).splitlines() if s.strip().strip(",")]


def iter_objects(text):
    """Yield (obj_id, isa, body) for every top-level object in the archive."""
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        match = OBJ_HEADER_RE.match(lines[index])
        if not match:
            index += 1
            continue
        indent, obj_id, remainder = match.groups()
        if remainder.rstrip().endswith("};"):
            body, index = remainder.rstrip()[:-2], index + 1
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


class Project(object):
    def __init__(self, text, root):
        self.root = root
        self.refs, self.groups, self.parent = {}, {}, {}
        self.build_files, self.phases, self.targets, self.synced = {}, {}, {}, {}
        self.exception_sets = {}

        for obj_id, isa, body in iter_objects(text):
            if isa == "PBXFileReference":
                self.refs[obj_id] = attrs_of(body)
            elif isa in ("PBXGroup", "PBXVariantGroup"):
                self.groups[obj_id] = attrs_of(body)
                for child in list_of(body, "children"):
                    self.parent[child] = obj_id
            elif isa == "PBXFileSystemSynchronizedRootGroup":
                info = attrs_of(body)
                info["exceptions"] = list_of(body, "exceptions")
                self.synced[obj_id] = info
                for child in list_of(body, "children"):
                    self.parent[child] = obj_id
            elif isa == "PBXFileSystemSynchronizedBuildFileExceptionSet":
                self.exception_sets[obj_id] = strings_of(
                    body, "membershipExceptions")
            elif isa == "PBXBuildFile":
                ref = re.search(r"fileRef\s*=\s*(%s)\b" % HEX, body)
                self.build_files[obj_id] = ref.group(1) if ref else ""
            elif isa == "PBXSourcesBuildPhase":
                self.phases[obj_id] = list_of(body, "files")
            elif isa == "PBXNativeTarget":
                info = attrs_of(body)
                info["buildPhases"] = list_of(body, "buildPhases")
                info["synced"] = list_of(body, "fileSystemSynchronizedGroups")
                self.targets[obj_id] = info

    def path_of(self, node_id):
        parts, seen, current = [], set(), node_id
        while current and current not in seen:
            seen.add(current)
            info = (self.refs.get(current) or self.groups.get(current)
                    or self.synced.get(current) or {})
            if info.get("path"):
                parts.append(info["path"])
            if info.get("sourceTree") in ("SOURCE_ROOT", "<absolute>"):
                break
            current = self.parent.get(current)
        return os.path.join(*reversed(parts)) if parts else ""

    def effective_sources(self, target_id):
        """[(relpath, origin)] that this target actually compiles."""
        target = self.targets[target_id]
        out = []
        for phase_id in target["buildPhases"]:
            for build_id in self.phases.get(phase_id, []):
                ref = self.build_files.get(build_id, "")
                rel = self.path_of(ref)
                if rel:
                    out.append((rel, "Compile Sources"))
        for group_id in target["synced"]:
            info = self.synced.get(group_id, {})
            folder = self.path_of(group_id)
            excluded = set()
            for ex_id in info.get("exceptions", []):
                excluded.update(self.exception_sets.get(ex_id, []))
            base = os.path.join(self.root, folder)
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [d for d in dirnames
                               if not d.startswith(".")
                               and not d.endswith(".xcodeproj")]
                for name in filenames:
                    if not name.endswith(".swift"):
                        continue
                    rel_in = os.path.relpath(
                        os.path.join(dirpath, name), base)
                    if rel_in in excluded:
                        continue
                    out.append((os.path.join(folder, rel_in),
                                "synced folder %s/" % folder))
        return out


def digest(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha1(f.read()).hexdigest()[:10]
    except IOError:
        return "unreadable"


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

    root = os.path.dirname(os.path.dirname(os.path.abspath(pbx))) or "."
    print("=" * 70)
    print("MileLog project doctor")
    print("=" * 70)

    try:
        running = subprocess.call(["pgrep", "-x", "Xcode"],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL) == 0
    except OSError:
        running = None
    if running:
        print("\n!! Xcode is RUNNING — it will overwrite edits made here.")
        print("!! Quit Xcode before using --fix.")

    print("\nProject: %s" % os.path.abspath(pbx))
    print("Root:    %s" % root)

    with open(pbx, "r", encoding="utf-8") as f:
        text = f.read()
    proj = Project(text, root)

    print("\n-- Targets ---------------------------------------------------")
    for tid, info in sorted(proj.targets.items(),
                            key=lambda kv: kv[1].get("name", "")):
        sources = proj.effective_sources(tid)
        print("  %-22s %s" % (info.get("name", tid),
                              info.get("productType", "")))
        print("      effective .swift inputs: %d" % len(sources))
        explicit = sum(1 for _, o in sources if o == "Compile Sources")
        print("      via Compile Sources:     %d" % explicit)
        print("      via synced folders:      %d" % (len(sources) - explicit))

    print("\n-- Synchronized folders (Xcode 16) ---------------------------")
    if not proj.synced:
        print("  none")
    for gid, info in proj.synced.items():
        owners = [t.get("name", "?") for t in proj.targets.values()
                  if gid in t["synced"]]
        print("  %-24s used by: %s" % (proj.path_of(gid) + "/",
                                       ", ".join(owners) or "(no target)"))

    print("\n-- Name collisions per target --------------------------------")
    collisions_found = {}
    for tid, info in sorted(proj.targets.items(),
                            key=lambda kv: kv[1].get("name", "")):
        by_base = {}
        for rel, origin in proj.effective_sources(tid):
            by_base.setdefault(os.path.basename(rel).lower(), []).append(
                (rel, origin))
        clashes = {b: v for b, v in by_base.items() if len(v) > 1}
        name = info.get("name", tid)
        if not clashes:
            print("  %-22s clean" % name)
            continue
        collisions_found[tid] = clashes
        print("  %-22s %d COLLISIONS  <-- this is the build failure"
              % (name, len(clashes)))
        for base in sorted(clashes):
            print("      %s" % base)
            for rel, origin in clashes[base]:
                print("          %-44s  [%s]" % (rel, origin))

    print("\n-- Duplicate .swift basenames on disk ------------------------")
    on_disk = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "build", "DerivedData")
                       and not d.endswith(".xcodeproj")]
        for name in filenames:
            if name.endswith(".swift"):
                on_disk.setdefault(name.lower(), []).append(
                    os.path.relpath(os.path.join(dirpath, name), root))
    dupes = {k: v for k, v in on_disk.items() if len(v) > 1}
    if not dupes:
        print("  none (%d .swift files, all uniquely named)" % len(on_disk))
    else:
        print("  %d names exist in more than one place. Comparing copies:\n"
              % len(dupes))
        identical, differing = [], []
        for name in sorted(dupes):
            rows = []
            for rel in sorted(dupes[name]):
                full = os.path.join(root, rel)
                stat = os.stat(full)
                rows.append((rel, stat.st_size,
                             time.strftime("%Y-%m-%d %H:%M",
                                           time.localtime(stat.st_mtime)),
                             digest(full)))
            same = len({r[3] for r in rows}) == 1
            (identical if same else differing).append((name, rows))
        for label, bucket in (("IDENTICAL content", identical),
                              ("DIFFERENT content", differing)):
            if not bucket:
                continue
            print("  --- %s (%d) ---" % (label, len(bucket)))
            for name, rows in bucket:
                print("    %s" % name)
                for rel, size, mtime, sha in rows:
                    print("        %-42s %7d B  %s  %s"
                          % (rel, size, mtime, sha))
            print("")
        if identical and not differing:
            print("  Every duplicate is byte-identical, so deleting either")
            print("  copy loses nothing.")
        elif differing:
            print("  Some copies DIFFER. Keep the one you have been editing —")
            print("  check the dates above before deleting anything.")

    if not do_fix:
        print("\n(read-only; nothing was written)")
        return 0

    if not collisions_found:
        print("\n--fix: no collisions to resolve. Nothing written.")
        return 0
    if running:
        print("\n--fix refused: quit Xcode first, or it will undo the change.")
        return 1

    # Drop the explicit Compile Sources entry whenever a synced folder already
    # supplies a file of that name. The synced copy is the one inside the
    # target's own source folder, so it is the one to keep.
    remove_ids = set()
    for tid, clashes in collisions_found.items():
        target = proj.targets[tid]
        for base, group in clashes.items():
            if not any(o.startswith("synced") for _, o in group):
                continue
            for phase_id in target["buildPhases"]:
                for build_id in proj.phases.get(phase_id, []):
                    ref = proj.build_files.get(build_id, "")
                    rel = proj.path_of(ref)
                    if rel and os.path.basename(rel).lower() == base:
                        remove_ids.add(build_id)

    if not remove_ids:
        print("\n--fix: collisions are between two explicit entries, not a")
        print("synced folder. Resolve by hand — see the listing above.")
        return 1

    kept = []
    for line in text.splitlines(True):
        entry = ENTRY_RE.match(line.rstrip("\n"))
        if entry and entry.group(2) in remove_ids:
            continue
        if "isa = PBXBuildFile;" in line and line.lstrip()[:24] in remove_ids:
            continue
        kept.append(line)
    shutil.copy2(pbx, pbx + ".bak")
    with open(pbx, "w", encoding="utf-8") as f:
        f.write("".join(kept))
    print("\n--fix: removed %d duplicate Compile Sources entries." % len(remove_ids))
    print("Backup: %s.bak" % pbx)
    print("Reopen Xcode, then Product > Clean Build Folder.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
