#!/usr/bin/env python3
"""A local stand-in for Linear's GraphQL endpoint.

    linear-stub.py <scenario.json>

Serves test-resolve-ids.sh (bin/resolve-ids.py) and any test that runs
skills/board/starved.py against a fixture board.

Binds a loopback TCP port chosen by the OS, prints that port number (and
nothing else) to stdout, then serves forever until killed. This is the only
handshake the test needs: read one line, and the stub is ready.

`<scenario.json>` describes the fixture Linear world this run answers with:

    {
      "teams":    [{"id": "...", "name": "..."}, ...],
      "projects": [{"id": "...", "name": "...", "teamId": "..."}, ...],
      "states":   [{"id": "...", "name": "...", "type": "..."}, ...],
      "labels":   [{"id": "...", "name": "..."}, ...],
      "label_id_lies": {"<id>": "<name the round-trip query lies and returns>"},
      "issues":   [{"projectId": "...", "stateId": "...", "identifier": "...", ...}, ...],
      "fail_after": <int, optional>,
      "log": "<path, optional>"
    }

`issues`: fixture Todo-column cards for starved.py's `query TodoIssues`. Each
entry carries `projectId` and `stateId` alongside the node fields starved.py
reads (`identifier`, `priority`, `createdAt`, `labels`, `history`,
`inverseRelations`) -- the stub matches those two routing keys against the
query's variables and strips them before returning the node, the same way
Linear's own filter never echoes back what it filtered on.

Every request is routed by matching a fixed substring of its GraphQL document
against the operation names resolve-ids.py's and starved.py's own query
documents carry (`query Team`, `query Project`, `query States`,
`query Labels`, `mutation CreateLabel`, `query LabelById`,
`query TodoIssues`) -- this stub does not implement Linear's schema, only the
shapes those two callers actually send.

`fail_after`: the Nth request onward gets HTTP 500. Requests are counted from
1 across the whole run, in the order resolve-ids.py issues them (team,
project, states, labels-list, then per-label create/verify) -- this is what
lets a test say "fail on the third query" and mean it.

`label_id_lies`: models a Linear bug (or an attacker) where the id round-trip
query returns a name that does not match the label that id was resolved for.
This is the fixture for the "label id belongs to a differently-named label"
REFUSE case -- resolve-ids.py's own bookkeeping is never what is wrong here,
only what the server hands back for that one id.

`log`: if set, one line per request is appended as `<operation> <variables
as JSON>`, so a test can assert not just what ids.env ended up with but which
requests were actually sent -- e.g. that reusing an existing label sends no
CreateLabel mutation for it.
"""

from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def _operation_name(document: str) -> str:
    for name in (
        "query Team",
        "query Project",
        "query States",
        "query Labels",
        "mutation CreateLabel",
        "query LabelById",
        "query TodoIssues",
    ):
        if name in document:
            return name
    return "unknown"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: linear-stub.py <scenario.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1]) as handle:
        scenario = json.load(handle)

    state = {"requests": 0, "created_labels": {}}

    def all_labels() -> list:
        return list(scenario.get("labels", [])) + list(state["created_labels"].values())

    def route(document: str, variables: dict) -> dict:
        op = _operation_name(document)

        if op == "query Team":
            nodes = [t for t in scenario.get("teams", []) if t.get("name") == variables.get("name")]
            return {"teams": {"nodes": nodes}}

        if op == "query Project":
            nodes = [
                p
                for p in scenario.get("projects", [])
                if p.get("name") == variables.get("name")
                and p.get("teamId") == variables.get("teamId")
            ]
            return {"team": {"projects": {"nodes": nodes}}}

        if op == "query States":
            return {"team": {"states": {"nodes": scenario.get("states", [])}}}

        if op == "query Labels":
            return {"team": {"labels": {"nodes": all_labels()}}}

        if op == "mutation CreateLabel":
            name = variables.get("name")
            new_id = f"created-{len(state['created_labels']) + 1}-{name}"
            state["created_labels"][new_id] = {"id": new_id, "name": name}
            return {
                "issueLabelCreate": {
                    "success": True,
                    "issueLabel": {"id": new_id, "name": name},
                }
            }

        if op == "query LabelById":
            label_id = variables.get("id")
            lies = scenario.get("label_id_lies", {})
            if label_id in lies:
                return {"issueLabel": {"id": label_id, "name": lies[label_id]}}
            for label in all_labels():
                if label["id"] == label_id:
                    return {"issueLabel": {"id": label_id, "name": label["name"]}}
            return {"issueLabel": None}

        if op == "query TodoIssues":
            project_id = variables.get("projectId")
            state_id = variables.get("stateId")
            nodes = [
                {k: v for k, v in issue.items() if k not in ("projectId", "stateId")}
                for issue in scenario.get("issues", [])
                if issue.get("projectId") == project_id and issue.get("stateId") == state_id
            ]
            return {"issues": {"nodes": nodes}}

        raise ValueError(f"stub: unrecognised GraphQL document: {document[:120]!r}")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args) -> None:  # keep test output quiet
            pass

        def do_POST(self) -> None:
            state["requests"] += 1
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)

            fail_after = scenario.get("fail_after")
            if fail_after is not None and state["requests"] > fail_after:
                self._respond(500, {"errors": [{"message": "stub: induced failure"}]})
                return

            try:
                body = json.loads(raw)
                document = body.get("query", "")
                variables = body.get("variables", {})
                data = route(document, variables)
            except Exception as exc:  # noqa: BLE001 - report as a GraphQL error, not a crash
                self._respond(400, {"errors": [{"message": f"stub: {exc}"}]})
                return

            log_path = scenario.get("log")
            if log_path:
                with open(log_path, "a") as log_handle:
                    log_handle.write(f"{_operation_name(document)} {json.dumps(variables, sort_keys=True)}\n")

            self._respond(200, {"data": data})

        def _respond(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
