"""Tests for scripts/check-test-results.py, the verdict the tests workflow uses.

xcodebuild exits 0 when the scheme selects no tests, so the workflow cannot
take "green" from its exit status alone. Each case runs the script and asserts
its exit status, per rule 1 in test_checks.py.

prior-art-checked: ios-core's scripts/xcresult_summary.py has the same verdict
(`--mode gate`), but this repository's CI must not depend on an ios-core checkout.

    python3 -m pytest scripts/tests/ -q
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE = os.path.join(SCRIPTS, "check-test-results.py")


def _run(tmp_path, summary) -> subprocess.CompletedProcess:
    path = tmp_path / "summary.json"
    path.write_text(summary if isinstance(summary, str) else json.dumps(summary))
    return subprocess.run([sys.executable, GATE, str(path)], capture_output=True, text=True)


def _summary(total, passed, failed=0, skipped=0):
    # Key names as `xcrun xcresulttool get test-results summary --format json`
    # writes them (Xcode 16 and later).
    return {"totalTestCount": total, "passedTests": passed, "failedTests": failed,
            "skippedTests": skipped, "expectedFailures": 0, "result": "Passed"}


def test_a_run_with_passes_and_one_skip_is_green(tmp_path):
    result = _run(tmp_path, _summary(315, 314, skipped=1))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "315 tests (314 passed, 0 failed, 1 skipped)" in result.stdout


def test_a_run_that_executed_nothing_is_red(tmp_path):
    result = _run(tmp_path, _summary(0, 0))
    assert result.returncode == 1
    assert "no tests executed" in result.stdout


def test_a_summary_without_counts_is_red(tmp_path):
    result = _run(tmp_path, {"result": "Passed"})
    assert result.returncode == 1


def test_a_run_where_every_test_skipped_is_red(tmp_path):
    result = _run(tmp_path, _summary(4, 0, skipped=4))
    assert result.returncode == 1
    assert "no test passed" in result.stdout


def test_one_failure_among_many_passes_is_red(tmp_path):
    result = _run(tmp_path, _summary(315, 314, failed=1))
    assert result.returncode == 1
    assert "1 failed" in result.stdout


def test_unreadable_input_is_an_input_error_not_a_verdict(tmp_path):
    result = _run(tmp_path, "not json")
    assert result.returncode == 2
