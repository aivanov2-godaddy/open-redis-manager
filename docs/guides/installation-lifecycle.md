# Installation, upgrade and uninstall

> **Development stage:** a manual install/uninstall script exists under [`packaging/`](../../packaging/README.md). Source-matched fresh install, repeated install, uninstall, repeated uninstall, and reinstall passed on one disposable cPanel host; the broader supported-host matrix, upgrades, and full account lifecycle remain unvalidated. This is not a production installer. See the [sanitized lifecycle record](../validation/records/2026-11-22-current-source-install-lifecycle.md).

## Installation flow

1. Check root authorization and supported cPanel/WHM, OS and package-manager versions.
2. Inspect available Redis and Valkey packages, services and existing account data without modifying them.
3. Report missing PHP extension prerequisites and relevant memory headroom.
4. Install panel assets and register least-privilege cPanel and WHM entry points.
5. Create root-owned backend policy and per-account metadata; run each service with an account-specific systemd unit and private socket.
6. Verify panel registration and that no pre-existing Redis service or account configuration changed.

## Upgrade flow

- Back up ORM-owned metadata before schema changes.
- Preserve existing backend, service identity, port, credentials, user data and owner permissions unless an operator chooses a migration.
- Run versioned migrations once, validate state and keep a rollback path for ORM-owned files.
- Detect partial upgrades and report recovery steps instead of blindly repeating destructive operations.
- A new host backend policy only affects newly provisioned instances; do not switch existing accounts automatically.

## Uninstall flow

- Explain which plugin files, service registrations and metadata will be removed.
- Preserve account data and Redis/Valkey processes by default; allow explicit opt-in cleanup only after account-by-account review.
- Remove only paths owned by ORM and report leftover user data without deleting it.
- Verify cPanel/WHM registrations are removed while unrelated control-panel files stay untouched.

The current uninstaller refuses to proceed while any managed instance metadata remains. This prevents removal of the launcher or service template while an account service may rely on it. It does not remove Redis or Valkey data.

## Runtime prerequisites

Applications may require a Redis client extension/library in addition to the server process. The server service layer and customer PHP runtime are separate concerns; see the [CloudLinux guide](cloudlinux.md).
