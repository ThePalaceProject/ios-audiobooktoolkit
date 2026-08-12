#!/usr/bin/env python3
"""Fail if a test source file exists on disk but is not a member of the test target.

Three test files sat in this repository for months without ever being compiled:
`ManifestFormatTests.swift`, `TrackTransitionTests.swift` and
`NowPlayingTimeTests.swift` had zero project references. They looked like
ordinary tests in every editor and every code review, and every "the suite is
green" statement about this repository silently excluded them. When they were
finally registered, they produced 178 failing assertions, four of which
described a real defect in chapter navigation (PP-4948).

Nothing detected that, because there is nothing that CAN detect it by reading
the code: a file's membership of a target lives in `project.pbxproj`, not in the
file. This script is that check.

No dependencies beyond the standard library, so anyone can run it:

    python3 scripts/check-test-target-membership.py

Exit status is 0 when every test file is a member, 1 otherwise.
"""

from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(REPO, "PalaceAudiobookToolkit.xcodeproj", "project.pbxproj")
TARGET = "PalaceAudiobookToolkitTests"
TEST_DIR = os.path.join(REPO, TARGET)

# Files that are deliberately not compiled into the target. Add with a reason.
EXEMPT: dict[str, str] = {}


def die(message: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def section(pbxproj: str, name: str) -> str:
    """The text of one `/* Begin <name> section */ … /* End … */` region.

    Working per-section matters: an object's id also appears wherever the object
    is *referenced*, so a whole-file search finds the reference in some other
    section before the definition.
    """
    match = re.search(
        r"/\* Begin " + name + r" section \*/(.*?)/\* End " + name + r" section \*/",
        pbxproj,
        re.DOTALL,
    )
    return match.group(1) if match else ""


def blocks(section_text: str) -> dict[str, str]:
    """`id -> body` for every top-level object in a section.

    Ids are matched as 24 alphanumeric characters rather than 24 hex digits:
    Xcode generates hex, but hand-authored entries in this project do not
    (`PP17865001AAAA0001AAAA01`), and a hex-only pattern skipped them silently —
    which made four already-registered files look like orphans.
    """
    found = {}
    for match in re.finditer(
        r"^\t\t([0-9A-Za-z]{24})\b.*?=\s*\{(.*?)\};\s*$",
        section_text,
        re.DOTALL | re.MULTILINE,
    ):
        found[match.group(1)] = match.group(2)
    return found


def target_source_basenames(pbxproj: str) -> set[str]:
    """Basenames of every source file in the test target's Sources build phase."""
    file_refs = {}
    for ref_id, body in blocks(section(pbxproj, "PBXFileReference")).items():
        path = re.search(r"\bpath = \"?([^\";]+)\"?;", body)
        if path:
            file_refs[ref_id] = path.group(1)

    build_files = {}
    for build_id, body in blocks(section(pbxproj, "PBXBuildFile")).items():
        ref = re.search(r"\bfileRef = ([0-9A-Za-z]{24})\b", body)
        if ref:
            build_files[build_id] = ref.group(1)

    targets = blocks(section(pbxproj, "PBXNativeTarget"))
    target_body = next(
        (body for body in targets.values() if re.search(r"\n\t\t\tname = " + TARGET + r";", body)),
        None,
    )
    if target_body is None:
        die(f"could not find the {TARGET} native target in project.pbxproj")

    phases = re.search(r"buildPhases = \((.*?)\);", target_body, re.DOTALL)
    if not phases:
        die(f"{TARGET} has no buildPhases list")
    phase_ids = set(re.findall(r"^\s*([0-9A-Za-z]{24}) /\*", phases.group(1), re.MULTILINE))

    sources = blocks(section(pbxproj, "PBXSourcesBuildPhase"))
    for phase_id, body in sources.items():
        if phase_id not in phase_ids:
            continue
        files = re.search(r"files = \((.*?)\);", body, re.DOTALL)
        if not files:
            continue
        names = set()
        for build_id in re.findall(r"^\s*([0-9A-Za-z]{24}) /\*", files.group(1), re.MULTILINE):
            ref = build_files.get(build_id)
            if ref and ref in file_refs:
                names.add(os.path.basename(file_refs[ref]))
        return names

    die(f"{TARGET} has no PBXSourcesBuildPhase")


def main() -> int:
    if not os.path.isfile(PBXPROJ):
        die(f"no project file at {PBXPROJ}")
    if not os.path.isdir(TEST_DIR):
        die(f"no test directory at {TEST_DIR}")

    compiled = target_source_basenames(open(PBXPROJ, encoding="utf-8", errors="replace").read())

    on_disk = []
    for root, _dirs, files in os.walk(TEST_DIR):
        for name in files:
            if name.endswith(".swift"):
                on_disk.append(os.path.relpath(os.path.join(root, name), REPO))

    orphans = [
        path for path in sorted(on_disk)
        if os.path.basename(path) not in compiled and os.path.basename(path) not in EXEMPT
    ]

    if orphans:
        print(f"{len(orphans)} test file(s) exist on disk but are not compiled into {TARGET}:\n")
        for path in orphans:
            print(f"  {path}")
        print(
            "\nThese will never run, and every 'suite green' figure excludes them.\n"
            "Add them to the target, or record an exemption with a reason in EXEMPT."
        )
        return 1

    print(f"ok: all {len(on_disk)} test files under {TARGET}/ are members of the target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
