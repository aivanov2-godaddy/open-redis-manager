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

- The first read-only slice is available as `php bin/orm backend:discover --json`. It checks fixed common Linux binary paths and known systemd units; it does not change the host or inspect account data.
- The standalone command is CLI-only. The separate WHM entrypoint calls the same discovery class only after AppConfig and the PHP ACL check grant root-level access; the unauthenticated prototype UI remains disconnected.
- Supported cPanel package paths, Linux/systemd behavior, permissions, and live backend discovery still need validation on a disposable supported host before this issue can close.
