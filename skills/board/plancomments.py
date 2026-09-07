#!/usr/bin/env python3
"""Find the operator comments a plan has not answered yet, from Linear alone.

    plancomments.py < comments.json

Reads one card's comments as JSON on stdin -- a list, as Linear MCP returns
them, or an object with a `comments` list. Writes one JSON object on stdout:

    {
      "round": 2,                                     # plan comments posted so far
      "next_round": 3,
      "unconsumed": [{"id": "d4e5f6", "body": "..."}],
      "footer": "<!-- foreman:plan round=3 consumed=d4e5f6 -->",
      "plan_comments": ["a1b2c3"],
      "malformed_footers": []
    }

`unconsumed` is what `brief.py replan` renders; `footer` is the line the plan
comment about to be posted must end with. Nothing else on the card is repeated
back, so a card with a hundred comments and nothing new prints an empty list.

Why the footer exists at all: the board writes to Linear through MCP, which acts
as the operator's OWN user. A board comment and an operator comment therefore
share an author, a workspace and a shape -- there is no field on either one to
discriminate on.

The obvious substitute is a timestamp watermark: remember the newest board
comment and treat everything after it as new. That loses one specific race, and
loses it silently. The operator comments at 14:00 while the agent is still
revising; the agent finishes and the board posts the new plan at 14:05; the
14:00 comment is now older than the newest board comment and is never read by
anyone. For a column whose whole purpose is that the operator can talk to it,
a dropped question is the worst failure available, and nobody is told.

So every plan comment the board posts declares what it consumed, in a footer,
and unconsumed input is any comment whose id appears in no footer on the card.
That is derivable from the comment thread by itself: no sidecar, no clock, and
no assumption about the order Linear returns rows in.

Two rules fall out of it, and both are the whole point:

  * `consumed` is the UNION over EVERY footer on the card, never just the
    newest. Round 3's footer names only what round 3 consumed; reading it alone
    makes round 1's comments unconsumed again, and the board re-sends them to
    the agent on every tick forever.
  * A `foreman:plan` marker this file cannot parse consumes NOTHING. "I cannot
    read this marker" must never resolve to "everything is consumed" -- that
    direction drops the operator's words silently, and the other direction costs
    one duplicated comment in one prompt. It is reported in `malformed_footers`
    and on stderr so the bug is visible while the card keeps moving.

This holds no Linear key and opens no socket. reconcile.py has never held one
and this is not the change that gives the board one; the tick reads the thread
through MCP and pipes it here. That is also what makes the protocol directly
testable, which matters for a mechanism whose failure mode is silence.
"""

from __future__ import annotations

import json
import re
import sys
from typing import NoReturn

# Every HTML comment in a body, innards captured. Footers are found by scanning
# the whole body rather than only its last line: Linear renders and re-wraps
# markdown, and an operator quoting a plan comment inline puts a real footer
# somewhere other than the end.
HTML_COMMENT = re.compile(r"<!--(.*?)-->", re.DOTALL)

# The footer, exactly. `consumed` may be empty -- that is round 1, which
# consumed nothing -- but both keys must be present and in this order, because
# the board writes this string itself and anything else is not a footer it
# wrote. Deviations are reported, never guessed at.
FOOTER = re.compile(r"^foreman:plan\s+round=(\d+)\s+consumed=(\S*)$")

# What may appear in the comma-separated `consumed` list. Linear ids are UUIDs;
# this is deliberately wider, and deliberately excludes the comma and every
# space -- an id holding either would desynchronise the list the same way an
# embedded NUL desynchronises bin/contract.py's wire format.
ID = re.compile(r"^[A-Za-z0-9_.:-]+$")

MARKER = "foreman:plan"


def die(message: str) -> NoReturn:
    sys.stderr.write(f"plancomments: {message}\n")
    raise SystemExit(1)


def warn(message: str) -> None:
    sys.stderr.write(f"plancomments: warning: {message}\n")


def collect(items: object, into: list[dict], depth: int = 0) -> None:
    """Flatten the thread into one list, replies included.

    A reply written under a plan comment is a reply to the plan, and reading
    only the top level would drop exactly the comments this file exists to
    find. Linear returns children either as a plain list or as a GraphQL
    connection (`{"nodes": [...]}`), so both are walked.
    """
    if not isinstance(items, list):
        die(f"expected a JSON list of comments, got {type(items).__name__}")
    if depth > 20:
        die("comment thread nests more than 20 deep; refusing rather than looping")

    for item in items:
        if not isinstance(item, dict):
            die(f"every comment must be a JSON object with an id and a body, not {item!r}")
        into.append(item)

        children = item.get("children")
        if children is None:
            continue
        if isinstance(children, dict) and "nodes" in children:
            children = children["nodes"]
        collect(children, into, depth + 1)


def id_of(comment: dict) -> str:
    identifier = comment.get("id")
    if not isinstance(identifier, str) or not ID.match(identifier):
        die(f"invalid comment id {identifier!r}; expected a string of "
            "letters, digits, '.', ':', '_' or '-'")
    return identifier


def body_of(comment: dict, identifier: str) -> str:
    """The comment's text, with a null body read as empty.

    Linear returns a null body for a comment that carries only an attachment or
    a reaction. That is a real comment the operator wrote, and it still needs to
    reach the agent -- so it is kept with an empty body rather than refused,
    which would park the card on something the operator cannot see or undo.
    """
    body = comment.get("body")
    if body is None:
        return ""
    if not isinstance(body, str):
        die(f"{identifier}: body must be a string or null, not {type(body).__name__}")
    return body


def footers(body: str, identifier: str) -> tuple[list[int], set[str], bool]:
    """Every foreman:plan footer in one body: its rounds, its ids, and whether
    any marker in it failed to parse.

    A body with no `foreman:plan` marker at all is an operator comment and
    returns nothing -- that is the common case and is not malformed. Only a
    marker that announces itself as ours and then does not parse is.
    """
    rounds: list[int] = []
    consumed: set[str] = set()
    malformed = False

    for inner in HTML_COMMENT.findall(body):
        text = inner.strip()
        if not text.startswith(MARKER):
            continue

        match = FOOTER.match(text)
        if not match:
            warn(f"{identifier}: unreadable foreman:plan footer {text!r}; "
                 "treating it as having consumed nothing")
            malformed = True
            continue

        # An empty `consumed` is one element ("") only if split on the empty
        # string, so the empty list -- round 1, which consumed nothing -- is
        # spelled out rather than falling out of the split.
        raw = match.group(2)
        ids = raw.split(",") if raw else []
        if any(not ID.match(part) for part in ids):
            # An empty element, from a trailing comma or a doubled one, means
            # the list was truncated or edited. Reading half a consumed list as
            # a whole one is the silent-drop failure again, so the whole footer
            # consumes nothing and says so.
            warn(f"{identifier}: malformed consumed list {raw!r}; "
                 "treating this footer as having consumed nothing")
            malformed = True
            continue

        rounds.append(int(match.group(1)))
        consumed.update(ids)

    return rounds, consumed, malformed


def unconsumed(comments: list[dict]) -> dict:
    """The whole computation, over an already-flattened comment list."""
    flat: list[dict] = []
    collect(comments, flat)

    seen: set[str] = set()
    parsed: list[tuple[str, str, bool]] = []  # id, body, is a plan comment
    consumed: set[str] = set()
    rounds: list[int] = []
    malformed: list[str] = []

    for comment in flat:
        identifier = id_of(comment)
        if identifier in seen:
            # Two rows under one id make "was this consumed" depend on which
            # copy the loop kept, and one of the operator's two comments is
            # then dropped or answered twice.
            die(f"{identifier}: appears twice; every comment must be listed once")
        seen.add(identifier)

        body = body_of(comment, identifier)
        found, ids, bad = footers(body, identifier)
        if bad:
            malformed.append(identifier)
        consumed.update(ids)
        rounds.extend(found)
        # A comment carrying a well-formed footer is one the board wrote. It is
        # excluded whether or not a later footer names it, because the board
        # must never hand the agent its own plan back as operator input --
        # nothing else on the card identifies the author. A comment whose ONLY
        # marker is unreadable is not excluded: it may be an operator quoting a
        # footer, and swallowing their words on the strength of a string this
        # file could not parse is the one outcome the protocol rules out.
        parsed.append((identifier, body, bool(found)))

    pending = [{"id": i, "body": b} for i, b, is_plan in parsed
               if not is_plan and i not in consumed]

    # The round the card is on is the highest a footer claims, not the number of
    # footers: a deleted plan comment must not renumber the rounds that follow
    # it. Its consumed ids go with it, so its operator comments become pending
    # again -- replayed rather than lost, which is the safe direction.
    current = max(rounds) if rounds else 0
    ids = ",".join(entry["id"] for entry in pending)

    return {
        "round": current,
        "next_round": current + 1,
        "unconsumed": pending,
        # Emitted even when nothing is pending: the first plan comment on a
        # card consumes nothing and still needs a footer, or round 2 has no
        # round 1 to subtract from.
        "footer": f"<!-- {MARKER} round={current + 1} consumed={ids} -->",
        "plan_comments": [i for i, _, is_plan in parsed if is_plan],
        "malformed_footers": malformed,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        die("usage: plancomments.py < comments.json")

    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        die(f"stdin is not valid JSON: {exc}")

    # Linear MCP has returned both shapes depending on the call. Accepting the
    # wrapper is not politeness: read as an unknown object it would yield "no
    # comments at all", which is indistinguishable from a quiet card and is the
    # one answer this file must never give by accident.
    if isinstance(payload, dict):
        if not isinstance(payload.get("comments"), list):
            die("expected a JSON list of comments, or an object with a "
                f"'comments' list; got an object with keys {sorted(payload)!r}")
        payload = payload["comments"]

    json.dump(unconsumed(payload), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
