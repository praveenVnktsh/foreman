"""Which review findings block a merge. One rule, read by every caller.

    from severity import is_blocking

`reconcile.py` decides whether a round blocked, and `brief.py fix` decides
which findings the fix agent is handed. Both used to compare a finding's
severity with the literal "blocking". A reviewer that wrote "Blocking",
"critical" or "high" -- the skill it runs grades CRITICAL, WARNING and NOTE --
then filed a real defect that neither caller counted, and the diff merged with
the finding open. Two copies of the rule would also drift, and a drift here is
a round that blocks in one file and merges in the other.

THE RULE IS AN ALLOW-LIST OF WHAT DOES NOT BLOCK. A severity nobody recognised
blocks, because the cost of the two mistakes is not the same: a note read as
blocking costs one fix round, and a blocking finding read as a note merges a
defect. Missing, empty, misspelt and never-seen-before severities all block.

`warning` is in the list even though a light review asks only for `blocking`
or `note`. STYLEGUIDE.md section 9 and the review brief both define `warning`
as recorded and never stopping a build, and a reviewer following either one
still writes it.
"""

from __future__ import annotations

NON_BLOCKING = frozenset({
    "note", "nit", "minor", "low", "info", "suggestion",
    "non-blocking", "nonblocking", "warning",
})


def is_blocking(finding: object) -> bool:
    """True unless `finding` is an object whose severity is known not to block.

    A finding that is not an object blocks: nobody can read its severity, and
    a finding nobody can read is not a finding that found nothing.
    """
    if not isinstance(finding, dict):
        return True
    severity = str(finding.get("severity", "")).strip().lower()
    return severity not in NON_BLOCKING
