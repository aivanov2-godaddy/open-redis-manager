# Build disposable cPanel integration environment and release gates

## Goal
Validate privileged behaviors on supported, disposable cPanel systems before production use.

## Acceptance criteria
- Documented server matrix covers supported OS, cPanel/WHM, CloudLinux, CageFS and PHP runtimes.
- Install, upgrade, migration, restore, recovery and uninstall scenarios are exercised on disposable systems.
- Account boundary and WHM ACL checks are verified.
- Failure injection covers unavailable binaries, bad permissions, full disk, stale metrics and failed rollback.
- Release notes distinguish implemented, experimental and planned features.
- No secret values are included in logs, test evidence or docs.

## Progress

- Added a redacted Gitleaks workflow for pull requests and pushes, with no public comments or uploaded scan artifacts. A custom rule rejects committed SSH destination strings. This strengthens source-control hygiene but does not replace disposable-host runtime validation.
