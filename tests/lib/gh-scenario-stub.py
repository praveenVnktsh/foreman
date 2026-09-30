#!/usr/bin/env python3
"""A `gh` that answers from a scenario file, and refuses anything unscripted.

    GH_STUB_SCENARIO=<scenario.json> GH_STUB_LOG=<calls.jsonl> gh <args...>

Put a `gh` that runs this file first on PATH. The code under test then runs
its own `subprocess` calls, argv building and JSON parsing for real, and only
GitHub is replaced.

`<scenario.json>` maps an argv pattern to an answer:

    {
      "run view 7 --json jobs": {"stdout": "{\"jobs\": []}"},
      "api repos/{owner}/{repo}/actions/jobs/77/logs": {"exit": 1, "stderr": "HTTP 404"},
      "api repos/{owner}/{repo}/pulls/5/files --paginate --jq *": {"stdout": "..."}
    }

The argv is normalised as the arguments after `gh`, joined by single spaces.
A key matches that string exactly, or as an `fnmatch` pattern. An exact key
wins. Two patterns matching one call is an error, not a choice: the scenario
said two different things about the same call.

An answer holds `stdout`, `stderr` (both default "") and `exit` (default 0).
Any other key is an error, so a typo such as `"code": 1` cannot quietly answer
with exit 0.

A call with `--json <fields>` and no `--jq` gets only the fields it asked for,
as real `gh` does. A scenario can then describe a whole object, and a caller
that stops asking for a field it reads sees that field go missing. Output that
is not JSON is passed through as written.

Every call is appended to `<calls.jsonl>` as one JSON line:
`{"argv": [...], "pattern": <key or null>, "exit": <int>}`. A test asserts on
which calls were made from that log.

An unscripted call exits 97 and prints its argv on stderr. The code under test
reads any nonzero exit as "gh failed", and a case about a failure could then
pass on a call nobody scripted. So the log records it too, and the harness
fails the case on any logged 97.
"""

from __future__ import annotations

import fnmatch
import json
import os
import sys

UNSCRIPTED = 97
ANSWER_KEYS = {"stdout", "stderr", "exit"}


def refuse(argv: list[str], why: str) -> int:
    print(f"gh-scenario-stub: {why}: gh {' '.join(argv)}", file=sys.stderr)
    return UNSCRIPTED


def find(scenario: dict, call: str) -> tuple[str | None, str]:
    """The key that answers `call`, or None and why no key does."""
    if call in scenario:
        return call, ""
    matches = [k for k in scenario if fnmatch.fnmatchcase(call, k)]
    if len(matches) > 1:
        return None, f"patterns {matches} all match"
    if not matches:
        return None, "unscripted call"
    return matches[0], ""


def fields_asked(argv: list[str]) -> list[str] | None:
    """The `--json` field list, or None when gh would not filter the output."""
    if "--json" not in argv or "--jq" in argv:
        return None
    at = argv.index("--json") + 1
    return argv[at].split(",") if at < len(argv) else None


def project(stdout: str, fields: list[str]) -> str:
    """`stdout` with every object cut down to `fields`, as gh answers."""
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        return stdout

    def cut(row: object) -> object:
        if not isinstance(row, dict):
            return row
        return {k: v for k, v in row.items() if k in fields}

    return json.dumps([cut(r) for r in data] if isinstance(data, list) else cut(data))


def log(path: str, argv: list[str], pattern: str | None, code: int) -> None:
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"argv": argv, "pattern": pattern, "exit": code}) + "\n")


def main(argv: list[str]) -> int:
    scenario_path = os.environ.get("GH_STUB_SCENARIO")
    log_path = os.environ.get("GH_STUB_LOG")
    if not scenario_path or not log_path:
        return refuse(argv, "GH_STUB_SCENARIO and GH_STUB_LOG must both be set")
    with open(scenario_path, encoding="utf-8") as f:
        scenario = json.load(f)
    pattern, why = find(scenario, " ".join(argv))
    if pattern is None:
        log(log_path, argv, None, UNSCRIPTED)
        return refuse(argv, why)
    answer = scenario[pattern]
    unknown = set(answer) - ANSWER_KEYS
    if unknown:
        log(log_path, argv, pattern, UNSCRIPTED)
        return refuse(argv, f"answer for {pattern!r} has unknown keys {sorted(unknown)}")
    code = answer.get("exit", 0)
    if not isinstance(code, int) or isinstance(code, bool):
        log(log_path, argv, pattern, UNSCRIPTED)
        return refuse(argv, f"answer for {pattern!r} has exit {code!r}, not an int")
    log(log_path, argv, pattern, code)
    stdout = answer.get("stdout", "")
    fields = fields_asked(argv)
    sys.stdout.write(project(stdout, fields) if fields and code == 0 else stdout)
    sys.stderr.write(answer.get("stderr", ""))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
