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
