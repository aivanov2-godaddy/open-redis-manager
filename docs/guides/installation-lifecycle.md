# Installation, upgrade and uninstall

> **Development stage:** a manual install/uninstall script now exists under [`packaging/`](../../packaging/README.md). It has not been run on a cPanel host and is not a production installer. This guide remains the checklist for the full lifecycle.

## Installation flow

1. Check root authorization and supported cPanel/WHM, OS and package-manager versions.
2. Inspect available Redis and Valkey packages, services and existing account data without modifying them.
3. Report missing PHP extension prerequisites and relevant memory headroom.
4. Install panel assets and register least-privilege cPanel and WHM entry points.
5. Create persistent metadata and privileged service boundaries with restrictive ownership.
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

The current uninstall script removes panel registrations and matching ORM interface files only. It does not remove Redis or Valkey processes, configuration, or data.

## Runtime prerequisites

Applications may require a Redis client extension/library in addition to the server process. The server service layer and customer PHP runtime are separate concerns; see the [CloudLinux guide](cloudlinux.md).
