# Live WHM unavailable EA Podman coverage report — 2026-11-22

## Scope and source identity

- This check exercised one authenticated WHM report request while no EA Podman metrics summary was available. It did not inspect live container counters or create a container.
- Platform: AlmaLinux 10.3 with cPanel & WHM 138.0 build 27 on one owner-designated test host. Host, account, domain, and network identifiers are omitted.
- Installed ORM product files matched repository source `0.1.0-rc.13` at base revision `e2fa8556208d15902fa36f04d215bfb79dac5d7c`. The live harness and authenticated form check were SHA-256 verified as `0c272ffd5fb487ae3999df1b9039c4a82da02b6f2ebe14331c326ef7ba0ea901` and `d5c07c7ee649c5b4a690446e2dcac67587b287296434731ea92728a0c55d9531`.

## Live results

| Check | Result | Evidence |
|---|---|---|
| Unavailable coverage rendering | PASS | With the summary path absent during the authenticated WHM request, the report rendered the unavailable-coverage explanation and marked Podman metrics and counter rates unknown. |
| Report flow | PASS | WHM SSO submitted the report-only POST; the generated report and normalized `security.report` audit event were verified. The normal one-minute report throttle was consumed. |
| Existing sampler state | RESTORED | The stale root-owned summary was restored with the same inode, content digest, owner, group, mode, size, modification time, and link count. An independent before/after comparison matched. The counter baseline remained absent. |
| Sampler services | UNCHANGED | The systemd timer remained disabled and inactive; its service remained inactive. |
| Redis/Valkey state | NOT CHANGED | No container lifecycle or Redis/Valkey configuration action was requested by this check. |
| Temporary files | CLEANED | The live harness removed its staged source bundle and sampler staging directory after validation. |

## Limits and sanitization

This confirms one unavailable-snapshot report path on one cPanel host. It does not establish host-wide inventory completeness or broader cPanel, OS, Redis, or Valkey compatibility. No credentials, host identifiers, account identifiers, domains, container IDs, keys, values, or counter values are included in this record.
