#!/usr/bin/env python3
"""Fail if a Markdown table row would silently lose cells when rendered.

GitHub-Flavored Markdown splits a table row into cells on `|` **before** it
parses inline spans. A code span does not protect a pipe: a cell containing
`` `a || b` `` becomes extra cells, and every cell past the header's width is
DROPPED from the rendered table with no warning.

That is not hypothetical here. `docs/followups.md` — the file this project used
so deferred work would not be forgotten — was broken this way twice in one week:
once by a blank line that terminated the table mid-way, and once by a row
describing a boolean expression, which dropped the Status from the single
highest-value row in the file. Both were found by a human reading a diff.

WHAT IS AND IS NOT AN ERROR. Only rows with TOO MANY cells fail, because only
those lose data. GFM pads a short row with empty cells, so a row with too few is
untidy but harmless and is not reported — an earlier draft failed those and would
have been noise. A header narrower than its own separator IS reported, because
the separator sets the table width and the mismatch means one of them is wrong.

No dependencies beyond the standard library:

    python3 scripts/check-markdown-tables.py [path ...]

With no arguments it scans every `.md` file git knows about, under the repo root.
Exit status is 0 when every table row is safe, 1 otherwise, 2 on a usage error.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A separator row: | --- | :--: | ---: |   (leading/trailing pipes optional in GFM)
SEPARATOR = re.compile(r"^\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?$")
# An opening or closing code fence, ``` or ~~~, optionally indented and tagged.
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")


def die(message: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def strip_prefix(line: str) -> str:
    """Remove up to three spaces of indent and any blockquote markers.

    GFM renders a table indented by up to three spaces, and one inside a
    blockquote. Both were invisible to an earlier draft, which meant a broken
    table in either position passed silently.
    """
    line = re.sub(r"^\s{0,3}", "", line)
    while line.startswith(">"):
        line = re.sub(r"^>\s?", "", line)
        line = re.sub(r"^\s{0,3}", "", line)
    return line


def is_table_row(line: str) -> bool:
    """A table row contains an unescaped pipe outside of code spans.

    GFM does not require leading or trailing pipes, so `a | b` is a row.
    """
    return "|" in line.replace(r"\|", "")


def cell_count(line: str) -> int:
    """Number of cells GFM will produce for a row.

    Escaped pipes (`\\|`) are removed first: they are the documented way to put
    a literal pipe in a cell and do NOT split it. Leading and trailing pipes are
    optional, so they are stripped before counting rather than assumed present.
    """
    body = line.replace(r"\|", "")
    body = body.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|"):
        body = body[:-1]
    return len(body.split("|"))


def check_file(path: str) -> tuple[list[str], int]:
    """Returns (problems, number of tables inspected).

    The table count is returned so a caller can tell a genuinely clean run from
    a vacuous one. An earlier draft's first "clean" run was green only because
    the files it scanned contained no tables at all.
    """
    problems: list[str] = []
    tables = 0
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as exc:
        return [f"{path}: could not read ({exc})"], 0

    expected: int | None = None
    in_fence = False

    for number, raw in enumerate(lines, 1):
        line = strip_prefix(raw.rstrip())

        # Fenced code blocks are documentation ABOUT markdown as often as they
        # are code. A fenced example of a broken table must not fail this check —
        # the likeliest author of one is whoever documents this very script.
        if FENCE.match(raw):
            in_fence = not in_fence
            expected = None
            continue
        if in_fence:
            continue

        if not is_table_row(line):
            # Any non-table line ends the table, INCLUDING a blank one. That is
            # how the ledger broke the first time: rows after the blank line are
            # no longer part of any table and render as literal text.
            expected = None
            continue

        if SEPARATOR.match(line):
            expected = cell_count(line)
            tables += 1
            header_no = number - 1
            if header_no >= 1:
                header = strip_prefix(lines[header_no - 1].rstrip())
                if is_table_row(header) and cell_count(header) != expected:
                    problems.append(
                        f"{path}:{header_no}: header has {cell_count(header)} cells but the "
                        f"separator declares {expected}"
                    )
            continue

        if expected is None:
            # A row preceding its separator is a header — legitimate. Anything
            # else is a pipe row belonging to no table, which renders as text.
            following = strip_prefix(lines[number].rstrip()) if number < len(lines) else ""
            if SEPARATOR.match(following):
                continue
            # Only the classic pipe-delimited form is reported as an orphaned
            # row. GFM allows a table without outer pipes, but so does ordinary
            # prose containing `a | b` — and flagging prose is how a check gets
            # switched off. The blank-line-in-a-table defect this exists to catch
            # produces rows that DO start with a pipe, so nothing is lost.
            if not line.startswith("|"):
                continue
            problems.append(
                f"{path}:{number}: pipe row is not part of any table (no separator "
                f"above it) — it will render as literal text: {line[:60]}"
            )
            continue

        actual = cell_count(line)
        if actual > expected:
            problems.append(
                f"{path}:{number}: row has {actual} cells but the table declares "
                f"{expected}, so {actual - expected} will be DROPPED  (an unescaped "
                f"'|' inside a cell — a code span does NOT protect it; write '\\|')"
            )

    return problems, tables


def markdown_files(paths: list[str]) -> list[str]:
    if paths:
        return paths
    # Ask git, so untracked scratch files and anything gitignored are excluded.
    # An earlier draft walked the filesystem and read `.pytest_cache/README.md`.
    try:
        out = subprocess.run(
            ["git", "-C", REPO, "ls-files", "-z", "*.md"],
            capture_output=True, check=True,
        ).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(REPO, p) for p in out.split("\0") if p)
    except (OSError, subprocess.CalledProcessError) as exc:
        die(f"could not list tracked files via git ({exc})")


def main(argv: list[str]) -> int:
    for arg in argv[1:]:
        if arg.startswith("-"):
            die(f"unknown option {arg!r}; this check takes file paths or nothing")

    files = markdown_files(argv[1:])
    problems: list[str] = []
    tables = 0
    for path in files:
        found, seen = check_file(path)
        problems.extend(found)
        tables += seen

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

    print(f"ok: {tables} table(s) across {len(files)} file(s); every row renders in full")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
