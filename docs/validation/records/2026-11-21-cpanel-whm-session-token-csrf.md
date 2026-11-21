# Live cPanel and WHM session-token CSRF check

**Date:** 2026-11-21

**Platform:** AlmaLinux 10.3 with cPanel & WHM 138.0 RELEASE, build 27

**Result:** Passed for no-token request rejection on both plugin surfaces.

## Source and method

Before the probe, the installed cPanel page, WHM CGI, and shared session-request guard matched the current repository source by SHA-256:

| File | SHA-256 |
|---|---|
| `packaging/cpanel/files/orm/index.live.php` | `450204f1f28cda5c44ecb417046d81555e4f7ddf3a13a7117e47f75ef3754d04` |
| `packaging/whm/cgi/addon_open_redis_manager.php` | `874c476901ea2b528a32654efc24d335dd70eb94a3c7e39045939185632b03d9` |
| `src/Orm/Security/SessionRequestGuard.php` | `c77c84291e6811dabbb5fdd398750157bf936005efbb59dd279c2de56d95f698` |

The live harness opened fresh cPanel and root WHM SSO sessions, loaded each ORM page through its valid `cpsess` route, and then sent an unsupported no-op POST to the same endpoint with the session cookies but without the `cpsess` path token. The test did not submit a supported ORM action.

## Results

| Check | Result |
|---|---|
| Source matched the repository | Pass |
| Valid cPanel SSO route | HTTP 200 |
| cPanel POST without `cpsess` | HTTP 401 |
| Valid root WHM SSO route | HTTP 200 |
| WHM POST without `cpsess` | HTTP 401 |
| Redis, Valkey, package, account, or policy state changed | No |
| Temporary harness removed | Pass |

The harness keeps session URLs, cookies, account names, and response bodies in memory and does not print or save them. The submitted action name is unsupported, so it cannot trigger a Redis/Valkey or WHM operation even if a request reaches the plugin. The offline session-guard test also checks that all cPanel and WHM POST forms leave their action URL implicit, preserving the active `cpsess` route, and that both entry points use the shared guard.

cPanel documents a unique per-session security token on each request as its CSRF protection mechanism ([cPanel glossary](https://docs.cpanel.net/knowledge-base/cpanel-product/cpanel-glossary/)).

## Limits

This verifies missing-token rejection on one cPanel & WHM release. It does not exercise valid-token state-changing actions, operation-specific authorization for every action, other cPanel versions, or the install/uninstall lifecycle. ORM's broader supported-host matrix remains open.
