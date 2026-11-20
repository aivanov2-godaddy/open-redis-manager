# WHM security report form smoke — 2026-11-20

## Test identity

- ORM source: signed `0.1.0-rc.3` candidate, matched against the repository's WHM CGI source.
- Host purpose: owner-designated cPanel test system.
- Authentication: root-only SSO session created with cPanel's `create_user_session` API and initialized with its returned login URL.
- Request transport: HTTPS to the SSO hostname, pinned to the local WHM listener. No credentials or session URL were retained.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| WHM SSO initialization | PASS | cPanel returned a valid temporary session and the login request established an authenticated cookie. |
| Root WHM form | PASS | The page included the root-only report threshold controls and report form. |
| Fleet-summary POST control | NOT VALIDATED | HTTP 200 returned HTML without the expected verified-summary markup. |
| Security-report POST action | PARTIAL | A new normalized `security.report` audit event was verified after the request. |
| Rendered report result | NOT VALIDATED | HTTP 200 returned HTML without the ORM report heading or generated timestamp. No response body was retained. |
| Policy, thresholds, or backend | NOT CHANGED | No configuration or backend-selection mutation was requested. |
| Redis keys, values, or credentials | NOT READ | The request path uses aggregate ORM metrics and normalized audit events only. |
| Rate limiter | CONSUMED | The report POST used the one-minute report throttle. |

## Result

The engine and authenticated report action ran, but the WHM response did not render the expected ORM report. The fleet-summary control response also lacked its expected markup, so the problem may extend beyond report construction. This test does not establish successful end-user rendering or production support. Repeat with an authenticated WHM browser and compare its request/response behavior before changing the report engine.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, SSO URLs/cookies, raw metrics, report contents, journal lines, and Redis key/value data. The reusable smoke is [`tests/whm-live-security-report-form.php`](../../../tests/whm-live-security-report-form.php).
