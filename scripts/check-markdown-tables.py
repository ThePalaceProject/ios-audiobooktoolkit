#!/usr/bin/env python3
"""Fail if a Markdown table row has the wrong number of cells.

GitHub-Flavored Markdown splits a table row into cells on `|` **before** it
parses inline spans. A code span does not protect a pipe: a cell containing
`` `a || b` `` becomes three cells, and every cell after the header's width is
silently DROPPED from the rendered table.

This is not hypothetical here. `docs/followups.md` is the follow-up ledger — the
place this project puts things so they are not forgotten — and it has been
broken this way twice:

  * a blank line inserted mid-table terminated it, so five rows including a
    deliberately-reopened one rendered as literal pipe text;
  * a row describing a boolean expression contained `||`, which split it into
    six cells against a four-column header and dropped its Status, on the single
    highest-value row in the file.

Both were found by a human reading the diff. Nothing checked it. A ledger whose
most important rows silently vanish is worse than no ledger, because it still
looks complete.

No dependencies beyond the standard library:

    python3 scripts/check-markdown-tables.py [path ...]

With no arguments it scans every tracked `.md` file under the repository root.
Exit status is 0 when every table row matches its header, 1 otherwise.
"""

from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A separator row: | --- | :--: | ---: |
SEPARATOR = re.compile(r"^\s*\|(\s*:?-+:?\s*\|)+\s*$")


def cell_count(line: str) -> int:
    """Number of cells in a pipe-delimited row.

    A row is written `| a | b |`, so splitting on `|` yields empty strings at
    both ends; hence the -2. Escaped pipes (`\\|`) are removed first because
    they do NOT split a cell — that is the documented way to put a literal pipe
    in a table.
    """
    return len(line.replace(r"\|", "").split("|")) - 2


def check_file(path: str) -> list[str]:
    problems: list[str] = []
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as exc:
        return [f"{path}: could not read ({exc})"]

    expected: int | None = None
    header_line = 0

    for number, raw in enumerate(lines, 1):
        line = raw.rstrip()
        if not line.startswith("|"):
            # A non-table line ends the current table. That includes a BLANK
            # line, which is how the ledger was broken the first time: the rows
            # after it are no longer part of any table and render as raw text.
            expected = None
            continue

        if SEPARATOR.match(line):
            # The separator defines the table's width; the header is the line
            # immediately above it.
            expected = cell_count(line)
            header_line = number - 1
            if header_line >= 1 and lines[header_line - 1].startswith("|"):
                actual = cell_count(lines[header_line - 1].rstrip())
                if actual != expected:
                    problems.append(
                        f"{path}:{header_line}: header has {actual} cells but the "
                        f"separator declares {expected}"
                    )
            continue

        if expected is None:
            # A header row legitimately precedes its separator, so look ahead
            # before complaining. Without this the check fires on EVERY table
            # header — and its first "clean" run was clean only because the
            # files it scanned contained no tables at all.
            following = lines[number].rstrip() if number < len(lines) else ""
            if SEPARATOR.match(following):
                continue
            # Otherwise this is a pipe row belonging to no table: it renders as
            # literal text. That is the blank-line-in-a-table breakage seen from
            # the other side.
            problems.append(
                f"{path}:{number}: pipe row is not part of any table (no separator "
                f"above it) — it will render as literal text: {line[:60]}"
            )
            continue

        actual = cell_count(line)
        if actual != expected:
            hint = ""
            if "|" in line.replace(r"\|", "")[1:-1] and actual > expected:
                hint = (
                    "  (an unescaped '|' inside a cell — a code span does NOT "
                    "protect it; write '\\|')"
                )
            problems.append(
                f"{path}:{number}: row has {actual} cells but the table declares "
                f"{expected}{hint}"
            )

    return problems


def markdown_files(paths: list[str]) -> list[str]:
    if paths:
        return paths
    found = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in {".git", "Carthage", "build"}]
        for name in files:
            if name.endswith(".md"):
                found.append(os.path.join(root, name))
    return sorted(found)


def main(argv: list[str]) -> int:
    files = markdown_files(argv[1:])
    problems: list[str] = []
    for path in files:
        problems.extend(check_file(path))

    if problems:
        print(f"{len(problems)} malformed Markdown table row(s):\n")
        for problem in problems:
            print(f"  {problem}")
        print(
            "\nGFM splits cells on '|' before parsing inline spans, so cells past "
            "the header's width are dropped from the rendered table without any "
            "warning."
        )
        return 1

    print(f"ok: every Markdown table row in {len(files)} file(s) matches its header")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
