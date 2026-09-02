#!/usr/bin/env python3
"""A local stand-in for Linear's GraphQL endpoint, for test-resolve-ids.sh.

    linear-stub.py <scenario.json>

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
      "state_create_lies": {"<name asked for>": "<name the create returns>"},
      "fail_after": <int, optional>,
      "log": "<path, optional>"
    }

Every request is routed by matching a fixed substring of its GraphQL document
against the operation names resolve-ids.py's own query documents carry
(`query Team`, `query Project`, `query States`, `mutation CreateState`,
`query Labels`, `mutation CreateLabel`, `query LabelById`) -- this stub does
not implement Linear's schema, only the shapes resolve-ids.py actually sends.

`fail_after`: the Nth request onward gets HTTP 500. Requests are counted from
1 across the whole run, in the order resolve-ids.py issues them (team,
project, states, any state create, labels-list, then per-label create/verify)
-- this is what lets a test say "fail on the third query" and mean it.

`state_create_lies`: {"name the mutation was asked for": "name it returns"}.
A state created under one name and returned under another is the fixture for
the REFUSE case where the board would park every question in a column nobody
is watching.

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
        "mutation CreateState",
        "query Labels",
        "mutation CreateLabel",
        "query LabelById",
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

    state = {"requests": 0, "created_labels": {}, "created_states": {}}

    def all_labels() -> list:
        return list(scenario.get("labels", [])) + list(state["created_labels"].values())

    def all_states() -> list:
        return list(scenario.get("states", [])) + list(state["created_states"].values())

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
            return {"team": {"states": {"nodes": all_states()}}}

        if op == "mutation CreateState":
            asked = variables.get("name")
            returned = scenario.get("state_create_lies", {}).get(asked, asked)
            new_id = f"created-state-{len(state['created_states']) + 1}"
            node = {"id": new_id, "name": returned, "type": variables.get("type")}
            state["created_states"][new_id] = node
            return {"workflowStateCreate": {"success": True, "workflowState": node}}

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
