# Complete WHM fleet recovery and aggregate visibility

## Goal
Finish the WHM fleet visibility and recovery work left after the original fleet workflow issue was closed. Keep every operation scoped to a selected cPanel account and preserve the fixed-command security boundary.

## Acceptance criteria
- WHM shows the exact verified-configured-account total, clear pagination, and normalized state totals explicitly scoped to the visible page. Unverifiable entries are distinct from failed services and are not represented as exact fleet-wide state totals.
- Root can request a read-only recovery scan for one selected account and see validated findings before any change.
- Any supported repair is a fixed, explicit action for one selected account; no arbitrary command or path input is accepted.
- Every scan and repair records the peer identity, account, action class, and outcome without storing secrets, raw command output, keys, or values.
- Unavailable services, malformed manifests, wrong ownership, timeouts, and failed repairs produce safe, actionable results without touching other accounts.
- Tests and docs cover access control, failure behavior, retention, and disposable-host release validation.

## Progress
- The current WHM page reports verified configured accounts across the inventory and page-scoped state counts; all-fleet live state totals remain deferred to a bounded snapshot design. Each account has a read-only recovery scan. Verified stopped/failed instances can offer only a fixed start repair, which rechecks the manifest and state while holding the existing per-account operation lock.
- Arbitrary Redis CLI execution is out of scope; only reviewed fixed operations may be added.
