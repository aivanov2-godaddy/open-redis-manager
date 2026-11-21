# Issue: Add selectable safe WHM Redis diagnostic command classes

Live issue: [#159](https://github.com/aivanov2-godaddy/open-redis-manager/issues/159), milestone 0.2.0.

## Goal

Expose the existing root-only diagnostics through a selectable WHM command console using a strict fixed allowlist.

## Acceptance criteria

- Select only `PING`, `INFO server`, `INFO memory`, `INFO clients`, `INFO stats`, and `DBSIZE`.
- Reject unknown classes and any caller-supplied Redis command or argument at the broker protocol boundary.
- Resolve the selected account through trusted ORM metadata and require a running instance.
- Return only exact, bounded typed fields for the selected class. Never expose raw output, keys, values, or credentials.
- Audit the root actor, account, exact command class, and outcome, including denied and rate-limited requests.
- Allow filtering audit records by each diagnostic command class.
- Retain the five-second per-account throttle and root-only WHM ACL/CSRF checks.
- Test the protocol, instance manager, fleet broker path, PHP client, audit viewer, and WHM UI; document the supported class list and limits.

## Not in scope

Arbitrary command text, Redis key browsing, key/value inspection, unbounded INFO output, or non-root command access.
