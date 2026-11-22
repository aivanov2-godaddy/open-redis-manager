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
- The cPanel entrypoint uses LiveAPI and the peer-credential broker for the signed-in account. The WHM entrypoint verifies the root-level ACL, renders read-only backend discovery, and delegates the fixed root-only account lifecycle controls to the broker. The issue's later progress history documents the expanded surfaces.
- The initial identity-only page was later expanded to read the authenticated account's broker status and expose account-scoped lifecycle controls. Identity and resource authorization still require verification across supported cPanel versions and themes.
- Added a Jupiter-targeted development installer/uninstaller using cPanel `install_plugin`/`uninstall_plugin` and WHM `register_appconfig`/`unregister_appconfig`, with collision checks and exact-file comparison before removal.
- On 2026-11-22, current commit `48c111d` passed source-matched fresh install, repeated install, uninstall, repeated uninstall, and reinstall on one AlmaLinux 10.3 / cPanel & WHM 138.0 build 27 RELEASE test host. Manifest, cPanel/WHM registrations, hook, broker state, and timer restoration were verified; see the [sanitized lifecycle record](../../docs/validation/records/2026-11-22-current-source-install-lifecycle.md).
- The source-matched live CSRF probe loaded both cPanel and root WHM pages through valid SSO routes, then confirmed unsupported POSTs without the `cpsess` path token were rejected with HTTP 401; it did not submit a supported ORM action. The [live session-token record](../../docs/validation/records/2026-11-21-cpanel-whm-session-token-csrf.md) covers one cPanel & WHM 138.0 build 27 host. Current offline checks pass for the shared session guard and mutation action/guard contract (44 assertions), WHM ACLs (19), and fleet UI (28). The action/guard contract verifies source wiring only; it is not valid-token live mutation evidence.
- Supported cPanel/WHM versions and themes, upgrade paths, uninstall with populated ORM-managed data, valid-token operation-specific mutation coverage across supported releases, browser review, and broader account-isolation validation remain open. The single-host lifecycle and CSRF probes do not establish product support or production readiness.
