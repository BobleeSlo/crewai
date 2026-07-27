#!/usr/bin/env python3
"""Compare this project's Swift sources against the reference copy in the
MileLog repo, and optionally refresh the stale ones.

A project assembled from several downloads over time ends up with files from
different revisions sitting side by side. That shows up as errors like
"Type 'SupabaseConfig' has no member 'passwordResetRedirect'" or "Extra
argument 'rate' in call": each file is valid on its own, they just come from
different points in the history.

This compares every .swift file under the project against the reference by
name and reports SAME / DIFFERS / MISSING, so the skew is visible in one
pass instead of one compiler error at a time.

Usage:
    python3 tools/check_sources.py                 # report only
    python3 tools/check_sources.py --sync          # overwrite stale copies
    python3 tools/check_sources.py --ref DIR       # compare against DIR

--sync only ever overwrites, never deletes, and writes a .bak beside each
file it changes.
"""

import hashlib
import io
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request

REF_SHA = "c404dd4c9f3560d6ca228dc0a662034f89ed31c1"
TARBALL = "https://codeload.github.com/BobleeSlo/crewai/tar.gz/%s" % REF_SHA


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()


def download(url):
    """Fetch a URL, falling back to curl when urllib has no CA bundle.

    python.org builds on macOS ship their own certificate store and ignore
    the system keychain, so urllib fails with CERTIFICATE_VERIFY_FAILED on a
    Mac where every other tool works. curl uses the system trust store.
    """
    try:
        with urllib.request.urlopen(url, timeout=120) as response:
            return response.read()
    except Exception as first_error:
        print("  urllib failed (%s) — retrying with curl" % type(first_error).__name__)
        temp = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                            "milelog-ref-download.tgz")
        status = subprocess.call(["curl", "-fsSL", "-o", temp, url])
        if status != 0:
            sys.exit("curl could not download %s either (exit %d)"
                     % (url, status))
        with open(temp, "rb") as f:
            return f.read()


def fetch_reference():
    print("Downloading reference sources (%s)..." % REF_SHA[:12])
    blob = download(TARBALL)
    dest = os.path.join(
        os.environ.get("TMPDIR", "/tmp"), "milelog-ref-%s" % REF_SHA[:12])
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        tar.extractall(dest)
    for root, dirs, _ in os.walk(dest):
        if os.path.basename(root) == "MileLog" and "Views" in dirs:
            return root
    sys.exit("could not locate the reference source folder in the tarball")


def main(argv):
    do_sync = "--sync" in argv
    ref = None
    if "--ref" in argv:
        ref = argv[argv.index("--ref") + 1]
    project = os.getcwd()

    if ref is None:
        ref = fetch_reference()
    print("Reference: %s" % ref)
    print("Project:   %s\n" % project)

    reference = {}
    for root, _, files in os.walk(ref):
        for name in files:
            if name.endswith(".swift"):
                reference[name] = os.path.join(root, name)

    local = {}
    for root, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs
                   if d not in (".git", "build", "DerivedData", ".build")
                   and not d.endswith(".xcodeproj")]
        for name in files:
            if name.endswith(".swift"):
                local.setdefault(name, []).append(os.path.join(root, name))

    same, differs, missing = [], [], []
    for name in sorted(reference):
        if name not in local:
            missing.append(name)
            continue
        ref_hash = sha(reference[name])
        for path in sorted(local[name]):
            rel = os.path.relpath(path, project)
            (same if sha(path) == ref_hash else differs).append((rel, name))

    extra = sorted(set(local) - set(reference))

    print("%-4d up to date" % len(same))
    print("%-4d STALE — differ from the reference" % len(differs))
    print("%-4d missing from this project" % len(missing))
    print("%-4d present here but not in the reference" % len(extra))

    if differs:
        print("\n-- STALE ------------------------------------------------")
        for rel, _ in differs:
            print("  %s" % rel)
    if missing:
        print("\n-- MISSING ----------------------------------------------")
        for name in missing:
            print("  %s" % name)
    if extra:
        print("\n-- NOT IN REFERENCE -------------------------------------")
        for name in extra:
            for path in local[name]:
                print("  %s" % os.path.relpath(path, project))
        print("  (left alone by --sync)")

    if not do_sync:
        print("\n(report only; nothing written — add --sync to refresh"
              " the stale files)")
        return 0
    if not differs:
        print("\n--sync: nothing to refresh.")
        return 0

    for rel, name in differs:
        path = os.path.join(project, rel)
        shutil.copy2(path, path + ".bak")
        shutil.copyfile(reference[name], path)
        print("refreshed %s" % rel)
    print("\n%d files refreshed, each with a .bak beside it." % len(differs))
    print("Nothing was deleted. Reopen Xcode and build.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
