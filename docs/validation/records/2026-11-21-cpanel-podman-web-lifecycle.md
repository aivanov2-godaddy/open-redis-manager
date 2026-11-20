# Authenticated cPanel EA Podman lifecycle form — 2026-11-21

## Test identity

- ORM source revision: `06460206a20abaa88f93c7812aa6bb00c58c9f42`.
- Platform: AlmaLinux 10.3, cPanel & WHM 11.138.0.27, RELEASE tier.
- Host purpose: owner-designated disposable cPanel test system.
- Authentication: cPanel `create_user_session` SSO for the account that owns the existing test cache.
- Test source: `tests/cpanel-live-podman-lifecycle-smoke.py`, SHA-256 `34bf33b6ffc8094f9ad5b081b6b63a6c4d9bdbb885a5befdfc79047783a729cf`.
- Installed `index.live.php` matched the repository file SHA-256 `450204f1f28cda5c44ecb417046d81555e4f7ddf3a13a7117e47f75ef3754d04`.
- Installed `PodmanLifecycleManager.php` matched the repository file SHA-256 `80c0e577a7557e418f24db93e8bd1c260c107e5d5895d1657a823ef88c5f81f1`.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| Authenticated account page | PASS | SSO loaded the source-matched cPanel page and its account identity matched the selected session. |
| Initial cache state | PASS | The account-owned EA Podman Redis cache was reachable before the test. |
| Stop form POST | PASS | The fixed account-level action stopped the cache; a fresh authenticated page showed its socket missing. |
| Start form POST | PASS | The fixed action started the same cache; a fresh authenticated page showed it reachable. |
| Restart form POST | PASS | The fixed action restarted the cache; a fresh authenticated page showed it reachable. |
| Final state and connection | PASS | The original running state was restored, the Unix socket was present, and an EasyApache PHP 8.5 PhpRedis PING succeeded. |
| Temporary test source | PASS | The transferred smoke script was removed after execution. |
| Redis data and configuration | NOT READ OR CHANGED | No keys, values, credentials, backend policy, package settings, or container configuration were inspected or changed. |

The smoke intentionally stopped the test cache briefly. It ran only `stop`, `start`, and `restart` through authenticated cPanel form submissions, verifying each result through a fresh account page. The script printed only a sanitized summary and retained no account name, container ID, socket path, session URL, cookie, or page body.

## Scope and limitations

This validates the authenticated cPanel web/session path for one EA Podman Redis container on one host. It does not establish Valkey web-form behavior, cross-account denial, direct ORM-managed Redis/Valkey lifecycle, backup/restore, migration, recovery, WHM ACL behavior, uninstall, CloudLinux/CageFS compatibility, or support for any host matrix. ORM production support remains **not established**.
