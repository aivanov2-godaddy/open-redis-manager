# Authenticated WHM report-threshold update and restore — 2026-11-22

## Test identity

- ORM source revision: `b1a1e4a` (`main` before the harness and record additions).
- Test harness: `tests/whm-live-security-report-form.php`, SHA-256 `7ad2b995db6aea83396fb24a0e10e8ff73cd2d00fdfa4675e1355e8ce530894f`.
- Installed WHM entry-point SHA-256: `a61abdb72af7a4b530cfc142d9fe7a90e7cf980dcca3b982b90db8aace504691`.
- Installed `WhmSecurityReportPolicyStore.php` SHA-256: `3f7c151ffde92074710682f98a57787b7036da13f3c7271fa00e632ead6fd74f`.
- Installed `WhmAuditEventWriter.php` SHA-256: `1789726d53454d6f4e25432cbfda64d6bab56183e581ad9a2ea11f140cf539d4`.
- Runtime: cPanel EA PHP 8.5.12 CLI with cURL and POSIX extensions.
- Host: the owner-designated disposable cPanel system described in the [RC12 guard validation](2026-11-21-cpanel-rc12-early-post-guard.md). Identifiers and raw operational output are omitted.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Installed-source match | PASS | The installed WHM entry point and threshold store/audit writer matched the checkout by SHA-256. The temporary harness hash matched the repository file before execution. |
| Valid-session threshold update | PASS | Root WHM SSO rendered the threshold form. A `security.policy.update` POST through the authenticated session temporarily changed one report-only threshold; WHM rendered its successful save confirmation and read the changed value back. |
| Effective-policy restoration | PASS | The harness submitted the original values through the same authenticated form and verified all three values. Initial settings were defaults; the changed value was restored to its original default. |
| Audit evidence | PASS | Two successful threshold-update metadata records were found in the system journal, corresponding to the temporary update and restore. |
| Host cleanup | PASS | The threshold file was absent before the test. After confirming the restored file contained only the exact default policy with root ownership and mode `0600`, it was removed to restore the original absent-file state. The temporary harness was also removed. |

This route changes only report severity thresholds; it does not enforce policy or change backend selection or Redis/Valkey services. The test briefly set one advisory threshold to a different value, then restored it. It created two metadata-only audit records.

## Scope and limitations

This validates one valid-token WHM state-changing action and restoration on one source-matched cPanel host. It does not validate other WHM mutation routes, all operation-specific authorization paths, cPanel mutations, other host combinations, or the complete support matrix. It does not establish ORM production support.

Overall result: PASS for the stated scenarios. ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

The record includes source hashes and sanitized results only. It contains no host or account identifiers, session URLs, cookies, credentials, policy values beyond the documented default-state outcome, or raw journal output.
