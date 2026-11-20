# WHM security report engine smoke — 2026-11-20

## Test identity

- ORM source: signed `0.1.0-rc.3` candidate from merged commit `87331b0`.
- Host purpose: owner-designated disposable cPanel test system.
- Platform: AlmaLinux 10.3, cPanel & WHM 138.0 RELEASE build 27.
- PHP runtime: cPanel's `/usr/local/cpanel/3rdparty/bin/php` CLI.
- Operation: root CLI invoked the installed ORM `BrokerClient`, `WhmAuditLog`, `WhmSecurityReportPolicyStore`, and `WhmSecurityReport` classes. Fleet metrics and normalized journal events were read; the report was built in memory.
- Reproduction: the exact committed [`tests/whm-live-security-report-engine.php`](../../../tests/whm-live-security-report-engine.php) smoke script was transferred through a root-only temporary directory, executed with cPanel PHP CLI, and removed after completion.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| Broker fleet summary | PASS | The installed broker returned a structurally verified fleet summary. No account names or metric values were retained. |
| ORM report construction | PASS | The report builder generated a report in `report-only` mode. |
| Audit source read | PASS | The bounded ORM journal read completed. No event contents were retained. |
| Report completeness | PARTIAL | The generated report marked its evidence partial; the live report content was not retained. |
| Authenticated WHM form submission | NOT IN THIS SMOKE | This engine-only check did not submit the form. A later root SSO form smoke is recorded separately; its POST wrote an audit event but did not return ORM report markup. |
| Policy or backend mutation | NOT RUN | The check did not write policy, create an audit event, consume the report rate limit, change a backend, or inspect Redis keys. |
| Valkey coverage | NOT RUN | No Valkey backend was queried. |

## Result

- Overall result: live report-engine path passed with partial evidence. End-user report rendering remains unverified; see the [separate authenticated form record](2026-11-20-whm-security-report-form.md).
- ORM support decision: `NOT ESTABLISHED`.
- Follow-up: reproduce the authenticated form response in a WHM browser session and verify rendered output; repeat the counter probe against Valkey.

## Sanitization review

This record omits the hostname, IP address, domain, account names, credentials, session URLs, private keys, raw metrics, report contents, journal lines, and Redis key/value data. The reusable live check is [`tests/whm-live-security-report-engine.php`](../../../tests/whm-live-security-report-engine.php).
