#!/usr/bin/env python3
"""Fail unless a test run executed tests, passed at least one, and failed none.

xcodebuild exits 0 when the scheme selects no tests, so the tests workflow
cannot take a green result from its exit status alone. This reads the summary
Xcode writes into the result bundle:

    xcrun xcresulttool get test-results summary --path R.xcresult --format json > s.json
    python3 scripts/check-test-results.py s.json

Exit status: 0 green, 1 red, 2 unreadable input.

prior-art-checked: the same verdict as ios-core's `scripts/xcresult_summary.py
--mode gate`, repeated here so this repository's CI needs no ios-core checkout.
"""

from __future__ import annotations

import json
import sys


def verdict(summary: dict) -> tuple[bool, str]:
    def count(key: str) -> int:
        return int(summary.get(key) or 0)

    total, passed, failed = count("totalTestCount"), count("passedTests"), count("failedTests")
    skipped, xfail = count("skippedTests"), count("expectedFailures")
    parts = [f"{passed} passed", f"{failed} failed"]
    if skipped:
        parts.append(f"{skipped} skipped")
    if xfail:
        parts.append(f"{xfail} expected-failure")
    label = f"{total} tests ({', '.join(parts)})"

    if total == 0:
        return False, f"no tests executed: {label}"
    if failed:
        return False, f"{failed} failed: {label}"
    if passed == 0:
        return False, f"no test passed (all skipped?): {label}"
    return True, label


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check-test-results.py <summary.json>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as f:
            summary = json.load(f)
    except (OSError, ValueError) as error:
        print(f"error: cannot read {argv[1]}: {error}", file=sys.stderr)
        return 2
    if not isinstance(summary, dict):
        print(f"error: {argv[1]} is not a JSON object", file=sys.stderr)
        return 2
    ok, message = verdict(summary)
    print(message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
