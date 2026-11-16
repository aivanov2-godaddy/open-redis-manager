# Live cPanel identity smoke record — 2026-11-16

## Test identity

- Test harness revision: `c0fc040` (`tests/cpanel-live-smoke.py`)
- Deployed ORM revision: not established by this run
- Host purpose: disposable test system
- OS: AlmaLinux 10.3
- cPanel & WHM: 138.0, build 24
- Architecture: not recorded
- CloudLinux: absent
- CageFS: absent
- cPanel internal PHP runtime reported by the host: 8.4.27
- EasyApache PHP runtime observed: 8.5.12; not separately exercised by this check
- Redis: one cPanel ea-podman container using Redis 6.2.24
- Valkey: not observed

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Fresh install and cPanel/WHM registration | NOT RUN | ORM was already installed; this read-only check did not alter registration. |
| Account identity | PASS | The temporary cPanel SSO session opened the ORM page, which reported a verified LiveAPI account identity through the local broker. |
| Cross-account denial | NOT RUN | No second account or cross-account request was used. |
| WHM ACL and root-only broker authorization | NOT RUN | No WHM mutation or fleet operation was attempted. |
| Provision, status, configure, start, stop, restart | NOT RUN | No Redis/Valkey lifecycle action was performed. |
| Metrics, backup/restore, migration, recovery, uninstall | NOT RUN | Not part of the read-only identity smoke. |
| Failure injection and CageFS/PHP Selector | NOT RUN | Not exercised. |

## Result

- Overall result: partial validation; the live cPanel account identity smoke passed.
- Known limitations: the installed source revision is unknown. The runtime inventory observed a Redis Podman container, but this check did not establish ORM backend discovery or test Redis/Valkey operations. No support claim is made for this host combination.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits the hostname, IP address, domain, account name, credentials, API token, session URL, private key, and raw operational output. The smoke script prints only a pass/fail result.
