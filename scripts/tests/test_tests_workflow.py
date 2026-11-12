"""Tests for .github/workflows/tests.yml's trust guard.

The unit-test job downloads Findaway's licensed AudioEngine.xcframework. It must
run only for trusted runs (pushes, workflow_dispatch, and pull requests from
branches in this repository), never for pull requests from forks, which is how
Android's builds handle Findaway.

    python3 -m pytest scripts/tests/ -q
"""

from __future__ import annotations

import fnmatch
import os

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW = os.path.join(REPO, ".github", "workflows", "tests.yml")

TRUSTED = (
    "github.event_name != 'pull_request' || "
    "github.event.pull_request.head.repo.full_name == github.repository"
)
FORK = (
    "github.event_name == 'pull_request' && "
    "github.event.pull_request.head.repo.full_name != github.repository"
)


def _doc() -> dict:
    with open(WORKFLOW) as f:
        return yaml.safe_load(f)


def _jobs() -> dict:
    return _doc()["jobs"]


def _normalise(expr) -> str:
    expr = str(expr or "").strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2].strip()
    return " ".join(expr.split())


def _fetches_audioengine(job: dict) -> bool:
    return any("cdn.audioengine.io" in str(step.get("run", "")) for step in job.get("steps", []))


def test_some_job_fetches_audioengine():
    # Guards the guard test below against passing vacuously if the fetch moves.
    assert any(_fetches_audioengine(job) for job in _jobs().values())


def test_every_job_that_fetches_audioengine_is_limited_to_trusted_runs():
    for name, job in _jobs().items():
        if _fetches_audioengine(job):
            assert _normalise(job.get("if")) == TRUSTED, f"job {name!r} fetches AudioEngine without the trust guard"


def test_fork_pull_requests_get_a_visible_skip_notice():
    notices = [
        job for job in _jobs().values()
        if _normalise(job.get("if")) == FORK
        and any("::notice::" in str(step.get("run", "")) for step in job.get("steps", []))
    ]
    assert len(notices) == 1
    assert not _fetches_audioengine(notices[0])



def _runs_for_base(pr: dict, base: str) -> bool:
    if "branches" in pr:
        return any(fnmatch.fnmatchcase(base, p) for p in pr["branches"])
    if "branches-ignore" in pr:
        return not any(fnmatch.fnmatchcase(base, p) for p in pr["branches-ignore"])
    return True


def test_pull_requests_into_feature_branches_skip_the_macos_job():
    # PyYAML reads the bare key `on` as True. A feature branch collects several
    # PRs and runs this job once, on its own PR into main.
    pr = _doc()[True]["pull_request"]
    assert not _runs_for_base(pr, "feature/PP-1-x")


def test_pull_requests_into_every_other_base_run_the_macos_job():
    pr = _doc()[True]["pull_request"]
    for base in ("main", "release/3.5.0", "hotfix/3.4.1-x", "fix/PP-1-y", "feat/x"):
        assert _runs_for_base(pr, base), f"a PR into {base} would not run the tests"
