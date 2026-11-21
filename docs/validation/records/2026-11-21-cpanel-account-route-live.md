# Current-source cPanel account route smoke — 2026-11-21

## Test identity

- Repository source: merged `main` commit `b571024dceac25294633f150e0e91fd1a627818c`.
- cPanel & WHM: `138.0 (build 27)`, RELEASE tier, AlmaLinux 10.3.
- Test environment: owner-designated disposable cPanel system; host, account, and domain identifiers are omitted.
- Installed `index.live.php`, `AuthenticatedAccountContext.php`, and `BrokerIdentityVerifier.php` matched the repository SHA-256 values before the run.
- Live harness: `tests/cpanel-live-smoke.py`, SHA-256 `c0706f7a1fe970fedcdeea80b8ad675ab7c54a02c6bb0bc604b5ce65ff8e530f`; copied to the host and removed after the run.

## Results

| Scenario | Result | Evidence |
|---|---|---|
| Authenticated cPanel SSO | PASS | The Jupiter ORM route loaded in the session created for the selected test account. |
| Account identity | PASS | The page's verified LiveAPI identity matched the SSO account. |
| Query-parameter spoofing | PASS | GET requests supplying `user`, `username`, or `account` as `root` kept the SSO-selected identity and returned HTTP 200. |
| Service and cache state | NOT CHANGED | The harness performed page GET requests only; no broker lifecycle operation or Redis/Valkey command was issued. |
| Session data | NOT RETAINED | The harness kept the SSO URL and cookies in memory and printed only the sanitized pass result. |

## Scope and limits

This source-matched check validates one account's cPanel entry point and query-spoof resistance on one host. It does not prove direct access denial across two real cPanel accounts, WHM ACL behavior, CSRF handling for all state-changing forms, install/uninstall idempotence, or a supported host matrix. ORM support remains **NOT ESTABLISHED**.

The record omits hostnames, IP addresses, domains, account names, SSO URLs/cookies, credentials, and raw page content.
