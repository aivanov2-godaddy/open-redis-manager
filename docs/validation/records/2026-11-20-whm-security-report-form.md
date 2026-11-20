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

## Follow-up reproduction

A second source-matched SSO run reproduced the same behavior. The POST response was HTTP 200 HTML classified as the generic WHM shell, with no ORM heading, report form, generated timestamp, or visible PHP error marker. The report action again produced a normalized audit event. The response body and session data were discarded.

As a read-only control, invoking the same installed CGI directly with a synthetic authenticated `fleet.summary` POST rendered the expected verified-summary heading. The installed CGI, report builder, and broker client matched the repository files byte-for-byte during this comparison. This narrows the difference to the HTTP/WHM request path; it does not yet identify its cause or prove browser form behavior.

The test records no response body and does not retain credentials, cookies, host identifiers, account data, report data, or raw logs. The report POST consumed the one-minute throttle and wrote one metadata-only audit event.

## Result

The engine and authenticated report action ran, but the HTTP response did not render the expected ORM report. The fleet-summary POST also lacked its expected markup, while direct invocation of the same installed CGI rendered that summary. The transport/request-path difference remains unresolved; this does not establish successful end-user rendering or production support. Issue [#71](https://github.com/aivanov2-godaddy/open-redis-manager/issues/71) is open while the defect is investigated.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, SSO URLs/cookies, raw metrics, report contents, journal lines, and Redis key/value data. The reusable smoke is [`tests/whm-live-security-report-form.php`](../../../tests/whm-live-security-report-form.php).
