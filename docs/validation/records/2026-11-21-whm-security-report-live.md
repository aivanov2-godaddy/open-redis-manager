# Live WHM report-only form smoke — 2026-11-21

## Scope and source identity

- Installed ORM candidate: `0.1.0-rc.8`, source commit `9ef35b7888f83b945ba4bc669c664547c3d57bac`.
- cPanel & WHM release: `138.0 (build 27)`.
- Test environment: owner-designated disposable cPanel system; server and account identifiers are omitted.
- The live harness from repository commit `2648c808be0cf43e050ef39fe17e6e1e255c63af` was verified by SHA-256 before execution. Its temporary file was removed after the run.

## Live results

| Scenario | Result | Evidence |
|---|---|---|
| Root WHM SSO and form | PASS | Authenticated cPanel-created SSO rendered the root-only report form. |
| Report POST | PASS | The authenticated WHM request returned the report section with a generated UTC timestamp. |
| Report audit | PASS | A new normalized `security.report` success event was verified after the POST. |
| Report throttle | CONSUMED | The test generated one report and consumed the one-minute report rate limit. |
| Policy and backend | NOT CHANGED | No policy threshold or backend-selection mutation was submitted. |
| Redis keys, values, and secrets | NOT READ | The report path reads aggregate metrics and normalized audit data; the harness retained no page body or report contents. |

The smoke does not validate every rendered finding or establish that all fleet signal sources are available. It verifies the authenticated form path, generated report response, and audit event. The live test intentionally creates one metadata-only audit event.

The reusable harness is [`tests/whm-live-security-report-form.php`](../../../tests/whm-live-security-report-form.php). Verified SHA-256: `29230e85825bd2deb6f59a132286761656ed425d8878c4f763ebfa2e730a4e05`.

## Limits and sanitization

This is an authenticated HTTP smoke, not a visual browser review, full security review, or support-matrix result. No live screenshot is claimed. The record omits hostnames, IP addresses, domains, account names, SSO URLs/cookies, report values, Redis values, credentials, and raw operational logs. The one-time test signing private key was not on the host or repository.
