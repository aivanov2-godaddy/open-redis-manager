# Establish cPanel and WHM plugin entry points

## Goal
Register account and administrator surfaces through supported cPanel/WHM interfaces while enforcing their separate permission boundaries.

## Acceptance criteria
- Supported cPanel/WHM versions and themes are declared.
- cPanel users can access only their own account's plugin route.
- WHM routes are protected by explicit WHM ACLs.
- All state-changing routes validate CSRF tokens.
- Install, upgrade, and uninstall are idempotent; uninstall preserves instance data by default.
- No privileged action is invoked directly by template code.

## Progress

- Added a cPanel `install.json` group/feature definition and `.live.php` page using the documented LiveAPI session wrapper.
- Added a WHM AppConfig registration with `acls=all`, a WHM PHP entrypoint, and a fail-closed check of the authenticated user against the fixed reseller ACL file.
- The cPanel entrypoint is a LiveAPI shell and does not access account data. The WHM entrypoint verifies the root-level ACL and renders only the read-only binary/version/service discovery result; it does not inspect account state or mutate the host.
- Installer lifecycle, file placement and permissions, cPanel/WHM compatibility, CSRF for future mutations, and real server validation remain open until tested on a disposable supported cPanel host.
