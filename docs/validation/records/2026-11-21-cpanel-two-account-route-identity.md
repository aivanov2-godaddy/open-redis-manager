# Current-source cPanel two-account route identity — 2026-11-21

## Test identity

- ORM commit: `464b1ad` (`main`).
- Test date: 2026-11-21.
- Host purpose: owner-designated disposable cPanel test system.
- Operating system: AlmaLinux 10.3.
- cPanel & WHM: 138.0 RELEASE, build 27.
- Test accounts: two existing cPanel accounts; no account was created or modified.
- Test harness: `tests/cpanel-live-smoke.py`, SHA-256 `c0706f7a1fe970fedcdeea80b8ad675ab7c54a02c6bb0bc604b5ce65ff8e530f`.
- Installed cPanel entry point, account-context helper, and broker-identity verifier matched their repository SHA-256 values before the test.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Authenticated page identity | PASS | Each of two cPanel SSO sessions loaded the ORM page with HTTP 200, and the displayed account identity matched the authenticated session. |
| Cross-account identity query spoofing | PASS | In both directions, setting each of `user`, `username`, and `account` to the other account did not change the authenticated identity. |
| Request type and mutation scope | PASS | The harness used GET requests only. It did not submit state-changing actions or perform Redis, Valkey, or Podman operations. |
| WHM ACL and mutation CSRF | NOT RUN | This page identity probe does not test WHM authorization or state-changing action protections. |
| Cleanup | PASS | The uploaded temporary harness was removed. SSO URLs and page responses remained in memory only and were not emitted in output or stored. |

## Installed source match

| Repository file | SHA-256 |
|---|---|
| `packaging/cpanel/files/orm/index.live.php` | `450204f1f28cda5c44ecb417046d81555e4f7ddf3a13a7117e47f75ef3754d04` |
| `src/Orm/Cpanel/AuthenticatedAccountContext.php` | `47c80f8d29c9665838a59f1c1a003f70e0fb7f0556c4775a022f5b8ac9ee95cc` |
| `src/Orm/Cpanel/BrokerIdentityVerifier.php` | `fbbd56792d04ac2b21d63b6ab264d561afad332a67cb79272c370cb26c1eac37` |

## Result

Current-source authenticated cPanel page identity and query-parameter spoof resistance passed in both directions on one disposable cPanel host. This does not validate state-changing route authorization, CSRF handling, WHM ACLs, other cPanel releases, or the broader production support matrix.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, SSO URLs, session cookies, tokens, and raw server output.
