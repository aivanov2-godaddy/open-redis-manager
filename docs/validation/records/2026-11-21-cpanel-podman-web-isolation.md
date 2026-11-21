# Two-account cPanel EA Podman web isolation — 2026-11-21

## Test identity

- ORM source revision on the test host: `5a67bfc537a0d3e3445d82f3fd9f6805bf481a68`.
- Platform: AlmaLinux 10.3, cPanel & WHM 138.0 build 27.
- Host purpose: owner-designated disposable cPanel test system.
- Authentication: separate cPanel `create_user_session` SSO sessions, used one at a time.
- Fixture: two disposable cPanel accounts, each with one existing account-owned EA Podman Redis cache and a reachable private Unix socket.
- Test source: `tests/cpanel-live-podman-web-isolation-smoke.py`, SHA-256 `35977444197787d0bf6d13d8dfedde3fad4af50dcefa87006c0245fa0927c0ef`.
- All six installed PHP files that govern account identity, page handling, cache discovery, session mutation checks, and EA Podman lifecycle matched the repository checkout. The cPanel entry page hash was `450204f1f28cda5c44ecb417046d81555e4f7ddf3a13a7117e47f75ef3754d04`; the lifecycle manager hash was `80c0e577a7557e418f24db93e8bd1c260c107e5d5895d1657a823ef88c5f81f1`.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| Fixture discovery | PASS | Each account's EA Podman inventory identified exactly one Redis container explicitly owned by that account. |
| Owner socket preflight | PASS | Both socket paths had the expected owner and private permissions. Owner-context Redis PING succeeded for both caches. |
| Account A attempts to stop account B's cache | PASS | The first ORM-page request after A's SSO returned HTTP 200, verified A's identity and own cache form, and the explicit generic denial. It showed no success message and did not echo B's container identifier. |
| Account B attempts to stop account A's cache | PASS | The same checks passed in the reverse direction using a separate sequential SSO session. |
| Post-request state | PASS | Repeated owner-context PINGs confirmed both caches remained reachable after both requests. Recovery was not needed. |
| Temporary test source | PASS | Transferred smoke files and temporary host-key data were removed after the run. |
| Redis data and configuration | NOT READ OR CHANGED | No keys, values, credentials, container configuration, or package settings were read or changed. |

The probe submitted only the fixed `stop` action against the other account's container ID in each direction. It did not stop either cache. The output retained no account name, domain, host address, container ID, socket path, SSO URL, cookie, page body, or raw command output.

## Session observation and scope

A separate read-only check found that the first ORM-page GET after SSO displayed the Podman cache section, while later GETs in that same SSO session returned HTTP 200 with the verified account identity but without that section. The exact cause was not established. To test the authorization handler without relying on those repeated reads, the cross-account probe submits its form as the first ORM-page request after SSO and verifies identity, denial, source-cache binding, and both owner PINGs in that response cycle.

This result validates cross-account denial for Redis EA Podman caches on one cPanel host and source-matched installation. It does not validate Valkey, a normal browser reload/action sequence, other cPanel releases, or the supported-host matrix. Investigate the repeated-GET behavior before treating the cPanel page lifecycle as fully validated.
