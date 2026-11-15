# Milestone draft: 0.1.0 — Safe cPanel integration foundation

**State:** local draft; not yet created in GitHub.

## Goal

Move ORM from a visual prototype to a safe, testable cPanel/WHM integration on disposable supported hosts.

## Scope

- cPanel and WHM entry points with server-side authorization.
- Redis/Valkey discovery and an account-isolated service adapter.
- cPanel status, lifecycle, configuration bounds and connection details.
- WHM account overview, safe recovery and audit events.
- Install/upgrade/uninstall behavior that preserves existing Redis data.
- Compatibility and validation documentation.

## Exit criteria

- Existing Redis instances are detected and preserved during install and upgrade.
- Account users cannot inspect or change another account's service.
- Root operations are behind a validated, least-privilege service boundary.
- Every privileged mutation is CSRF-protected, ACL-checked and audited.
- Install, migration rollback and uninstall have been exercised on disposable systems in the documented support matrix.
- User and admin documentation matches the tested build; no sample data is presented as live behavior.
