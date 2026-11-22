# Live WHM partial EA Podman coverage report — 2026-11-22

## Scope and source identity

- This check exercised one authenticated WHM report request with a synthetic, root-owned partial EA Podman metrics snapshot. It did not inspect live container counters or create a container.
- Platform: AlmaLinux 10.3 with cPanel & WHM 138.0 build 27 on one owner-designated test host. Host, account, domain, and network identifiers are omitted.
- Installed ORM source files matched repository source `0.1.0-rc.13` at base revision `ab8c830`. The live harness and authenticated form check were SHA-256 verified as `4ae44d09d1ac5ae8bf99c7ab837ba741f53027a42de8e71dec825744e8d605a0` and `74a073c89ebd3049f1f5fd95f14e70d363fc7fdcac3fd3e535fd5d242623540a`.

## Live results

| Check | Result | Evidence |
|---|---|---|
| Partial coverage rendering | PASS | A synthetic incomplete scan with one discovered Redis, one unmeasured probe, and an `incomplete_scan` counter window rendered the coverage and counter-rate findings as unknown in the authenticated WHM report. |
| Report flow | PASS | WHM SSO submitted the report-only POST; the generated report and normalized `security.report` audit event were verified. The normal one-minute report throttle was consumed. |
| Existing sampler state | RESTORED | The stale root-owned summary was restored with the same inode, content digest, owner, group, mode, size, and modification time. An independent before/after comparison matched. The counter baseline remained absent. |
| Sampler services | UNCHANGED | The systemd timer remained disabled and inactive; its service remained inactive. |
| Redis/Valkey state | NOT CHANGED | The synthetic summary was removed. No container lifecycle or Redis/Valkey configuration action was requested by this check. |
| Temporary files | CLEANED | The staged source bundle was removed after validation. |

## Limits and sanitization

This confirms one synthetic partial-coverage report path on one cPanel host. It does not establish host-wide inventory completeness, validate unavailable-source variants, or establish broader cPanel, OS, Redis, or Valkey compatibility. The synthetic report data was not actual Redis/Valkey telemetry. No credentials, host identifiers, account identifiers, domains, container IDs, keys, values, or counter values are included in this record.
