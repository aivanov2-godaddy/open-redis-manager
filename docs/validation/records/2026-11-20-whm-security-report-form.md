# WHM security report form smoke — 2026-11-20

## Test identity

- ORM source: signed `0.1.0-rc.3` candidate, matched against the repository's WHM CGI source.
- Host purpose: owner-designated cPanel test system.
- Authentication: root-only SSO session created with cPanel's `create_user_session` API and initialized with its returned login URL.
- Request transport: HTTPS to the SSO hostname, pinned to the local WHM listener. No credentials or session URL were retained.

## Initial reproduction and diagnosis

The original live smoke sent a fleet-summary POST immediately after loading the WHM page. The GET requests the root fleet inventory; the broker limits `fleet.list` to one request per peer per second. The rapid POST could therefore arrive while that inventory request was still rate-limited. The POST action could still generate its summary or report, but the page rendered those result sections only inside the successful fleet-inventory branch.

Temporary, sanitized runtime markers confirmed root authorization, a summary result, a missing fleet page, and execution through the WHM footer. This showed the action ran and the CGI completed its render path. It did not establish a browser session or retain page content. The root cause is the UI dependency on a transient inventory response during rapid successive requests.

## Fix and live results

The WHM page now renders the fleet-summary and security-report controls and results independently from the managed-instance inventory branch. Inventory-specific tables and controls remain conditional on verified inventory data.

| Scenario | Result | Sanitized observation |
|---|---|---|
| WHM SSO initialization | PASS | cPanel returned a valid temporary session and the login request established an authenticated cookie. |
| Root WHM form | PASS | The page included the root-only report threshold controls and report form. |
| Rapid fleet-summary POST | PASS | The read-only summary and security-report form rendered even on the fast path. |
| Rapid security-report POST | PASS | The report rendered with a generated timestamp, and its normalized audit event was verified. |
| Policy, thresholds, or backend | NOT CHANGED | No configuration or backend-selection mutation was requested. |
| Redis keys, values, or credentials | NOT READ | The request path uses aggregate ORM metrics and normalized audit events only. |
| Report rate limiter | CONSUMED | The report POST used the one-minute report throttle. |

The report-write smoke intentionally writes one metadata-only `security.report` audit event. The read-only fast fleet-summary smoke does not write audit data or consume the report throttle.

## Installed-source scope

The fixed CGI was temporarily installed for the two fast-path checks. After testing, the original installed CGI was restored and its SHA-256 matched the pre-test installed file. Temporary instrumentation and test files were removed. This is an authenticated HTTP smoke, not a browser visual review, a full package upgrade validation, or a supported-host matrix.

## Result

The WHM security report form and fast POST rendering passed on the cPanel test host after decoupling them from transient fleet inventory availability. Report-only behavior, the existing rate limit, and audit verification passed. Broader release compatibility gates remain tracked separately in the [validation matrix](../compatibility-matrix.md).

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, SSO URLs/cookies, raw metrics, report contents, journal lines, and Redis key/value data. The reusable smoke is [`tests/whm-live-security-report-form.php`](../../../tests/whm-live-security-report-form.php).
