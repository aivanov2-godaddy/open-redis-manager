# Authenticated WHM read-only fleet summary — 2026-11-22

## Test identity

- ORM source revision: `21bf630` (`codex/rc12-live-route-validation`).
- Test harness: `tests/whm-live-security-report-form.php`, SHA-256 `7e5b8ae506bcec33a2bc9f69d4470f30948eb482a55448934667d545a143a195`.
- Installed WHM entry-point SHA-256: `a61abdb72af7a4b530cfc142d9fe7a90e7cf980dcca3b982b90db8aace504691`.
- Installed `WhmAuditLog.php` SHA-256: `2a9f3f18eef02d479c4bcd75976660c5de1f18bd08b03e368fad93c0e2fb317a`.
- Runtime: cPanel EA PHP 8.5.12 CLI with cURL and POSIX extensions.
- The host is the owner-designated disposable cPanel system also described in the [RC12 guard validation](2026-11-21-cpanel-rc12-early-post-guard.md). Account names, domains, hostnames, addresses, credentials, session URLs, and cookies are omitted.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Installed-source match | PASS | The installed WHM CGI entry point and `WhmAuditLog.php` hashes matched the checked-out source files. The uploaded smoke harness hash matched the repository file before execution. |
| Authenticated WHM SSO | PASS | `whmapi1 create_user_session` created a root WHM SSO session; the harness followed redirects only within the same HTTPS WHM session. |
| Security-report form render | PASS | The authenticated WHM page returned HTTP 200 and contained the expected report form. |
| Valid-session POST route | PASS | The same authenticated `cpsess` path and cookie submitted `orm_action=fleet.summary`; WHM returned the rendered verified fleet-summary section. |
| Read-only scope and cleanup | PASS | The selected handler calls the root-only fleet summary operation. The harness did not request report generation, configuration changes, account/service operations, or an audit write. Its private cookie file was removed in `finally`; the temporary harness was removed from the host after its hash and successful run were verified. |

## Scope and limitations

This verifies one valid-session WHM POST carrying a read-only fleet-summary action on the source-matched cPanel host. It does not validate any state-changing action with a valid token, operation-specific authorization for every WHM action, cPanel web actions, other cPanel releases, or the supported-host matrix. It does not establish ORM production support.

Overall result: PASS for the stated scenarios. ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

The record contains source and test hashes plus sanitized outcomes only. It contains no host identifiers, account/domain details, session URLs, cookies, credentials, or raw response bodies.
