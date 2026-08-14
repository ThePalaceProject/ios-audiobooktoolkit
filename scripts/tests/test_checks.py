"""Tests for the repository's standalone checks.

Both checks exist because a real defect shipped and nothing noticed, so each test
is written against the defect that actually happened rather than an invented one.

Two rules this file learned the hard way, both from review:

1. **Test the gate, not a re-implementation of it.** An earlier version of
   `test_membership_detects_an_unregistered_file` computed the orphan set with a
   list comprehension in the test body. Deleting the entire orphan branch from
   `main()` left it passing — the check reported "ok" with a planted orphan and
   exited 0, reinstating exactly the hole it exists to close. The failure path is
   now exercised by running the script and asserting its exit status.
2. **Assert on input that actually exercises the bug.** The non-hex regression
   test asserted `ManifestJSON.swift`, whose object ids *are* hex — so it passed
   with the bug present. It now names a file whose ids are genuinely not hex.

    python3 -m pytest scripts/tests/ -q
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys

import pytest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(SCRIPTS)
MEMBERSHIP = os.path.join(SCRIPTS, "check-test-target-membership.py")
TABLES = os.path.join(SCRIPTS, "check-markdown-tables.py")


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

def _write(tmp_path, text: str, name: str = "doc.md") -> str:
    path = tmp_path / name
    path.write_text(text)
    return str(path)


VALID = """| # | Item | Status |
|---|---|---|
| 1 | a row | open |
| 2 | another | fixed |
"""


def test_valid_table_passes(tmp_path):
    problems, seen = tables.check_file(_write(tmp_path, VALID))
    assert problems == []
    assert seen == 1, "a clean result must be able to prove it actually saw a table"


def test_unescaped_pipe_in_a_cell_is_caught(tmp_path):
    """The `followups.md` defect: `||` inside a code span split the row into
    extra cells against the header, silently dropping the Status from the
    highest-value row in the ledger."""
    doc = VALID + "| 3 | matches `a || b` here | open |\n"
    problems, _ = tables.check_file(_write(tmp_path, doc))

    assert len(problems) == 1
    assert ":5:" in problems[0] and "DROPPED" in problems[0]


def test_escaped_pipe_is_allowed(tmp_path):
    doc = VALID + r"| 3 | matches `a \| b` here | open |" + "\n"
    assert tables.check_file(_write(tmp_path, doc))[0] == []


def test_blank_line_inside_a_table_is_caught(tmp_path):
    """The other `followups.md` defect: a blank line terminates the table, so
    rows after it render as literal pipe text — including, that time, a
    deliberately-reopened row whose whole purpose was visibility."""
    doc = VALID + "\n| 3 | orphaned | open |\n"
    problems, _ = tables.check_file(_write(tmp_path, doc))

    assert len(problems) == 1 and "not part of any table" in problems[0]


def test_short_rows_are_not_reported(tmp_path):
    """GFM pads a short row with empty cells, so nothing is lost. An earlier
    draft failed these, which would have been pure noise."""
    doc = VALID + "| 3 | only two |\n"
    assert tables.check_file(_write(tmp_path, doc))[0] == []


def test_header_narrower_than_separator_is_caught(tmp_path):
    doc = "| # | Item |\n|---|---|---|\n| 1 | a | b |\n"
    problems, _ = tables.check_file(_write(tmp_path, doc))
    assert any("header has 2 cells" in p for p in problems)


# --- false positives: every one of these must stay clean ---

def test_fenced_code_block_containing_a_broken_table_is_ignored(tmp_path):
    """Documentation ABOUT this check will contain a deliberately broken table.
    Failing that is the surest way to get the check deleted — and the hint would
    tell the author to escape a pipe inside a fence, corrupting the example."""
    doc = "Example of the defect:\n\n```markdown\n| a | b |\n|---|---|\n| x `p || q` | y |\n```\n"
    assert tables.check_file(_write(tmp_path, doc))[0] == []


def test_fenced_console_output_with_pipes_is_ignored(tmp_path):
    doc = "Output:\n\n```\n name | state\n------+------\n x    | ok\n```\n"
    assert tables.check_file(_write(tmp_path, doc))[0] == []


def test_tilde_fence_is_ignored(tmp_path):
    doc = "~~~\n| a | b | c |\n~~~\n"
    assert tables.check_file(_write(tmp_path, doc))[0] == []


def test_prose_containing_a_pipe_is_not_a_table(tmp_path):
    path = tmp_path / "doc.md"
    path.write_text("Run `a | b` to pipe them.\n\nMore prose.\n")
    assert tables.check_file(str(path))[0] == []


# --- table shapes GFM accepts that an earlier draft did not scan at all ---

def test_table_without_leading_and_trailing_pipes_is_scanned(tmp_path):
    """GFM makes the outer pipes optional. Not scanning these meant a broken
    table in that shape passed silently."""
    doc = "Item | Status\n--- | ---\nx `a || b` | open\n"
    problems, seen = tables.check_file(_write(tmp_path, doc))
    assert seen == 1
    assert len(problems) == 1 and "DROPPED" in problems[0]


def test_indented_table_is_scanned(tmp_path):
    doc = "   | a | b |\n   |---|---|\n   | x `p || q` | y |\n"
    problems, seen = tables.check_file(_write(tmp_path, doc))
    assert seen == 1 and len(problems) == 1


def test_blockquoted_table_is_scanned(tmp_path):
    doc = "> | a | b |\n> |---|---|\n> | x `p || q` | y |\n"
    problems, seen = tables.check_file(_write(tmp_path, doc))
    assert seen == 1 and len(problems) == 1


def test_unknown_option_is_rejected_not_ignored():
    """A check that silently accepts an interface it does not implement looks
    like it ran when it did not."""
    result = subprocess.run([sys.executable, TABLES, "--diff"], capture_output=True, text=True)
    assert result.returncode == 2 and "unknown option" in result.stderr


def test_repository_markdown_is_clean_and_not_vacuously_so():
    result = subprocess.run([sys.executable, TABLES], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    # Guard against the vacuous pass: if the repo ever has no tables left, this
    # test must fail loudly rather than keep reporting success.
    count = int(result.stdout.split("ok: ")[1].split(" table")[0])
    assert count >= 1, f"no tables scanned — this check is asserting nothing: {result.stdout}"


# --------------------------------------------------------------------------
# Test-target membership
# --------------------------------------------------------------------------

def test_repository_test_files_are_all_registered():
    result = subprocess.run([sys.executable, MEMBERSHIP], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_membership_detects_an_unregistered_file(tmp_path):
    """Reintroduce PP-4948: a test file on disk that no build phase names.

    This RUNS THE CHECK and asserts its exit status. The previous version
    computed the orphan set in the test body, so deleting `main()`'s entire
    orphan branch left it green while the check reported "ok" on a planted
    orphan.
    """
    fake = tmp_path / "repo"
    shutil.copytree(REPO, fake, symlinks=True, ignore=shutil.ignore_patterns(
        ".git", "Carthage", "build", "*.xcworkspace"))
    orphan = fake / "PalaceAudiobookToolkitTests" / "ZZOrphanProbe.swift"
    orphan.write_text("import XCTest\nfinal class ZZOrphanProbe: XCTestCase {}\n")

    result = subprocess.run(
        [sys.executable, str(fake / "scripts" / "check-test-target-membership.py")],
        capture_output=True, text=True,
    )

    assert result.returncode == 1, f"planted orphan not detected:\n{result.stdout}"
    assert "ZZOrphanProbe.swift" in result.stdout


def test_membership_passes_on_the_unmodified_tree(tmp_path):
    """The clean path, run the same way as the failing one — so the pair proves
    the check discriminates rather than always failing."""
    fake = tmp_path / "repo"
    shutil.copytree(REPO, fake, symlinks=True, ignore=shutil.ignore_patterns(
        ".git", "Carthage", "build", "*.xcworkspace"))

    result = subprocess.run(
        [sys.executable, str(fake / "scripts" / "check-test-target-membership.py")],
        capture_output=True, text=True,
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_membership_parser_reads_non_hex_object_ids():
    """Xcode generates 24-char hex ids; hand-authored entries in this project do
    not (`PP17865001AAAA0001AAAA01`). A hex-only pattern silently dropped four
    already-registered files and reported them as orphans.

    Asserts one of the four files the bug ACTUALLY dropped. The previous version
    asserted `ManifestJSON.swift`, whose ids are hex, so it passed with the bug
    present.
    """
    pbxproj = open(membership.PBXPROJ, encoding="utf-8", errors="replace").read()
    compiled = membership.target_source_paths(pbxproj)

    assert "BearerTokenRefreshTests.swift" in compiled
    assert "AudiobookManagerLifecycleTests.swift" in compiled


def test_membership_uses_the_test_targets_phase_not_any_target():
    """`ManifestJSON.swift` was moved OUT of the framework target and into the
    test target. A parser that unioned every target's sources phase would be
    unable to tell those apart, and would call an unregistered test file
    registered because some other target happened to compile a file of that name.
    """
    pbxproj = open(membership.PBXPROJ, encoding="utf-8", errors="replace").read()
    compiled = membership.target_source_paths(pbxproj)

    # A framework-only source must NOT appear in the test target's phase.
    assert "Tracks.swift" not in compiled
    assert "AudiobookTableOfContents.swift" not in compiled


def test_membership_rejects_arguments():
    result = subprocess.run([sys.executable, MEMBERSHIP, "--diff"], capture_output=True, text=True)
    assert result.returncode == 2 and "unexpected argument" in result.stderr
