# Live cPanel EA Podman Valkey lifecycle — 2026-11-21

## Test identity

- ORM application revision: `67576a3cb541cf243951fb98ec495f52a6631e64`.
- Platform: AlmaLinux 10.3, cPanel & WHM 11.138.0.27, RELEASE tier.
- Host purpose: owner-designated disposable cPanel test system.
- Authentication: cPanel `create_user_session` SSO for the account that owns the test caches.
- Lifecycle harness: `tests/cpanel-live-podman-lifecycle-smoke.py`, SHA-256 `260271446237079c1b7e4c46af353b729d7da6708c934701a9c7c9c3903245f6`.
- Installed `index.live.php` matched the repository file SHA-256 `450204f1f28cda5c44ecb417046d81555e4f7ddf3a13a7117e47f75ef3754d04`.
- Installed `PodmanCacheDiscovery.php` matched the repository file SHA-256 `43bf8add7bb8e45ad564867619a03dbb6d113c4ee2fd2bc88652e12bde44d126`.
- Installed `PodmanLifecycleManager.php` matched the repository file SHA-256 `80c0e577a7557e418f24db93e8bd1c260c107e5d5895d1657a823ef88c5f81f1`.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| Authenticated cPanel page | PASS | SSO loaded the source-matched ORM page and verified the selected account identity. |
| Backend targeting | PASS | The test account listed both Redis and Valkey; `--backend valkey` selected the Valkey card. Omitting a selector on a multi-container page now fails closed. |
| Valkey lifecycle POSTs | PASS | The authenticated page accepted the fixed stop, start, and restart actions; each resulting state was checked through a fresh page request. |
| Initial state restoration | PASS | The Valkey container returned to its initial running/stopped state. |
| Temporary Valkey cleanup | PASS | The temporary account-owned container was uninstalled with `--verify`; its only new backup was removed with account-scoped `ea-podman clean --run --days=0`. Final Valkey and backup counts were zero. |
| Existing Redis and root inventory | PASS | No lifecycle POST targeted Redis. Its account inventory and successful PING remained present before and after the Valkey run; the root-scoped container inventory fingerprint was unchanged across cleanup. |
| Temporary test files | PASS | The transferred lifecycle harness and install log were removed after execution. |
| Cache contents and configuration | NOT READ OR CHANGED | No keys, values, credentials, container configuration, or package settings were read or changed. |

The harness was transferred byte-for-byte from the recorded source hash. It emits only a sanitized pass/fail result and does not persist the account name, container ID, socket path, session URL, cookies, or page body.

## Scope and limitations

This validates authenticated cPanel form handling for one EA Podman Valkey container on one host and one account. It does not establish cross-account authorization, direct ORM-managed lifecycle, backup/restore, migration, recovery, WHM ACL behavior, uninstall behavior, CloudLinux/CageFS compatibility, or support for a broader host matrix. ORM production support remains **not established**.
