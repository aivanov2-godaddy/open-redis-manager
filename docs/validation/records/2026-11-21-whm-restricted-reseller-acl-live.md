# Current-source live WHM restricted-reseller ACL — 2026-11-21

## Test identity

- ORM commit: `505aac1` (`main`).
- Test date: 2026-11-21.
- Host purpose: owner-designated disposable cPanel test system.
- Operating system: AlmaLinux 10.3.
- cPanel & WHM: 138.0 RELEASE, build 27.
- Temporary fixture: one domainless reseller created only for this probe; its generated password was suppressed and never read or stored.
- Test harness: `tests/whm-live-acl-smoke.py`, SHA-256 `aeb8e19abe9e28b9ce35d1cb1c2b8f5e3e55271a1b641eb3d05dd25568c0b7b9`.
- The installed WHM CGI entry point and `WhmAcl` class matched the repository SHA-256 values below before the probe. The installed AppConfig registration declared `acls=all`.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Restricted reseller setup | PASS | The temporary reseller's `all` ACL was absent before SSO was created. The installed `WhmAcl` helper evaluated that authenticated reseller against the live reseller ACL file and returned denied. |
| WHM SSO | PASS | The restricted reseller SSO landing request returned HTTP 200. |
| ORM WHM page authorization | PASS | A GET to the installed ORM WHM CGI returned HTTP 401. Root-only discovery and report controls were absent. The response body, session URL, and cookies were not printed or stored. |
| State-changing actions | NOT RUN | The probe issued GET requests only; no WHM form was submitted. |
| Cleanup | PASS | The temporary reseller was removed. Account count returned to two, the reseller ACL records matched the pre-test state, no temporary reseller entry remained, and the uploaded harness was removed. |

## Installed source match

| Repository file | SHA-256 |
|---|---|
| `packaging/whm/cgi/addon_open_redis_manager.php` | `874c476901ea2b528a32654efc24d335dd70eb94a3c7e39045939185632b03d9` |
| `src/Orm/Security/WhmAcl.php` | `744be523d7fa46d867f121ba24f1bcc18ea1515297c27efff90edf0e5bace7b5` |

## Result

The current-source WHM entry point denied access in a real restricted-reseller SSO session on one disposable cPanel host, and the installed PHP ACL helper independently denied that reseller against the host's ACL file. This does not validate other cPanel releases or the complete host support matrix. State-changing WHM route CSRF behavior, the install/uninstall lifecycle, and the remaining release scenarios are still open.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, generated passwords, SSO URLs, cookies, tokens, private keys, and raw server output.
