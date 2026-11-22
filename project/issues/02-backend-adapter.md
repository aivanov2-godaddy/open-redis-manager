# Add account-isolated Redis and Valkey service adapter

## Goal
Create a backend interface for detection, provision, lifecycle, configuration, metrics and per-account migration.

## Acceptance criteria
- Detect binaries, service units and versions for supported Redis/Valkey packages.
- New-instance backend selection follows explicit WHM policy and host support.
- Upgrade preserves existing backend, port, credentials and data.
- Every service/config path is derived from trusted account metadata.
- No request data is interpolated into a shell command.
- Migration is explicit, snapshot-backed, verified, and rolls back on failure.

## Progress

- cPanel provisioning accepts only the fixed WordPress, Laravel, Magento, session-cache, or generic preset ID. The broker selects the memory cap and persists the selected preset in manifest v2; existing v1 manifests remain compatible and map to Generic.

- The first read-only slice is available as `php bin/orm backend:discover --json`. It checks fixed common Linux binary paths and known systemd units; it does not change the host or inspect account data.
- The standalone command is CLI-only. The separate WHM entrypoint calls the same discovery class only after AppConfig and the PHP ACL check grant root-level access; the unauthenticated prototype UI remains disconnected.
- PR #16 merged the root-only WHM selection for the installed default backend, account-derived instance manifests/configuration, and fixed systemd provision/start/stop/status operations through the broker. It uses no TCP listener and does not touch an existing Redis/Valkey unit.
- Migration now tracks its write-pause attempt, safety snapshot, service-stop, and backend-manifest transitions. An unexpected exception or ambiguous pause-command reply attempts to unpause the still-running Redis source or restore and verify the retained Redis snapshot after a stop/backend switch. Linux fixture coverage injects an ambiguous pause reply and exceptions before and immediately after the service-stop transition; this does not replace disposable cPanel migration validation.
- Linux CI, including broker tests, root-level package guard tests, and `systemd-analyze verify`, passes. The live cPanel smoke test still covers identity only; actual lifecycle remains unverified.
- Supported cPanel package paths, Linux/systemd behavior, permissions, and live backend discovery still need validation on a disposable supported host before this issue can close.
