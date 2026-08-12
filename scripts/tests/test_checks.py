"""Tests for the repository's standalone checks.

Both checks exist because a real defect shipped and nothing noticed, so each
test below is written against the defect that actually happened rather than an
invented one. Each check is also asserted to PASS on a correct input: a gate
that only ever sees violations is a gate nobody has proven can be satisfied,
and one of these very checks shipped a first draft that flagged every table
header — its "clean" run looked green only because the files it scanned had no
tables in them at all.

    python3 -m pytest scripts/tests/ -q
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys

import pytest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(SCRIPTS)


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, filename))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


tables = _load("check_markdown_tables", "check-markdown-tables.py")
membership = _load("check_test_target_membership", "check-test-target-membership.py")


# --------------------------------------------------------------------------
# Markdown tables
# --------------------------------------------------------------------------

def _write(tmp_path, text: str) -> str:
    path = tmp_path / "doc.md"
    path.write_text(text)
    return str(path)


VALID = """| # | Item | Status |
|---|---|---|
| 1 | a row | open |
| 2 | another | fixed |
"""


def test_valid_table_passes(tmp_path):
    """The clean path. A header preceding its separator is not an orphan."""
    assert tables.check_file(_write(tmp_path, VALID)) == []


def test_unescaped_pipe_in_a_cell_is_caught(tmp_path):
    """The `docs/followups.md` defect: `||` inside a code span split the row
    into six cells against a four-column header, silently dropping its Status —
    on the highest-value row in the ledger."""
    doc = VALID + "| 3 | matches `a || b` here | open |\n"
    problems = tables.check_file(_write(tmp_path, doc))

    assert len(problems) == 1
    assert ":5:" in problems[0]
    assert "5 cells" in problems[0] and "declares 3" in problems[0]


def test_escaped_pipe_is_allowed(tmp_path):
    """`\\|` is the documented way to write a literal pipe and must not trip."""
    doc = VALID + r"| 3 | matches `a \| b` here | open |" + "\n"

    assert tables.check_file(_write(tmp_path, doc)) == []


def test_blank_line_inside_a_table_is_caught(tmp_path):
    """The other `followups.md` defect: a blank line terminates the table, so
    every row after it renders as literal pipe text — including, that time, a
    deliberately-reopened row whose whole purpose was visibility."""
    doc = VALID + "\n| 3 | orphaned | open |\n"
    problems = tables.check_file(_write(tmp_path, doc))

    assert len(problems) == 1
    assert "not part of any table" in problems[0]


def test_header_narrower_than_separator_is_caught(tmp_path):
    doc = "| # | Item |\n|---|---|---|\n| 1 | a | b |\n"
    problems = tables.check_file(_write(tmp_path, doc))

    assert any("header has 2 cells" in p for p in problems)


def test_prose_containing_a_pipe_is_not_a_table(tmp_path):
    """A pipe in ordinary prose must not be mistaken for a malformed row."""
    path = tmp_path / "doc.md"
    path.write_text("Run `a | b` to pipe them.\n\nSome more prose.\n")

    assert tables.check_file(str(path)) == []


def test_repository_markdown_is_clean():
    """Dry-run on the real tree: the check must be satisfiable as committed."""
    result = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "check-markdown-tables.py")],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


# --------------------------------------------------------------------------
# Test-target membership
# --------------------------------------------------------------------------

def test_repository_test_files_are_all_registered():
    """The clean path, on the real project. This is the check whose absence let
    three test files sit uncompiled for months (PP-4948)."""
    result = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "check-test-target-membership.py")],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_membership_parser_reads_non_hex_object_ids():
    """Xcode generates 24-char hex ids, but hand-authored entries in this
    project are not hex (`PP17865001AAAA0001AAAA01`). A hex-only pattern
    silently skipped four already-registered files and reported them as
    orphans — a false positive that would have made the gate untrustworthy on
    its first run."""
    pbxproj = open(membership.PBXPROJ, encoding="utf-8", errors="replace").read()
    compiled = membership.target_source_basenames(pbxproj)

    assert "ManifestJSON.swift" in compiled
    assert any(not c.isdigit() for c in "".join(compiled)) or compiled


def test_membership_detects_an_unregistered_file(tmp_path):
    """Reintroduce the defect: a test file on disk that no build phase names."""
    pbxproj = open(membership.PBXPROJ, encoding="utf-8", errors="replace").read()
    compiled = membership.target_source_basenames(pbxproj)
    assert compiled, "precondition: the parser found the target's sources"

    on_disk = sorted(
        name for name in os.listdir(membership.TEST_DIR) if name.endswith(".swift")
    )
    assert on_disk, "precondition: there are test files to check"

    # A file present on disk but absent from the target is exactly PP-4948.
    orphans = [name for name in on_disk + ["NeverRegistered.swift"] if name not in compiled]
    assert orphans == ["NeverRegistered.swift"]
