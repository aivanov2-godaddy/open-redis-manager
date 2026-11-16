# Complete WHM fleet recovery and aggregate visibility

## Goal
Finish the WHM fleet visibility and recovery work left after the original fleet workflow issue was closed. Keep every operation scoped to a selected cPanel account and preserve the fixed-command security boundary.

## Acceptance criteria
- WHM shows fleet totals with clear pagination and health-state semantics.
- Root can request a read-only recovery scan for one selected account and see validated findings before any change.
- Any supported repair is a fixed, explicit action for one selected account; no arbitrary command or path input is accepted.
- Every scan and repair records the peer identity, account, action class, and outcome without storing secrets, raw command output, keys, or values.
- Unavailable services, malformed manifests, wrong ownership, timeouts, and failed repairs produce safe, actionable results without touching other accounts.
- Tests and docs cover access control, failure behavior, retention, and disposable-host release validation.

## Progress
- The current WHM page has paginated account inventory, per-account service and backup controls, guarded Redis-to-Valkey migration, and fixed read-only diagnostics for one running account. Fleet aggregates, recovery scans, and repair actions remain future work.
- Arbitrary Redis CLI execution is out of scope; only reviewed fixed operations may be added.
