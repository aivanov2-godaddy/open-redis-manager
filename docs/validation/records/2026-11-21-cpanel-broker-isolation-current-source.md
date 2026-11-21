# Current-source cPanel two-account broker isolation — 2026-11-21

## Test identity

- ORM commit: `7e895bc` (`main`).
- Test date: 2026-11-21.
- Host purpose: owner-designated disposable cPanel test system.
- Operating system: AlmaLinux 10.3.
- cPanel & WHM: 138.0 RELEASE, build 27.
- Test accounts: two existing cPanel accounts; no account was created or modified.
- Test harness: `tests/cpanel-live-isolation-smoke.py`, SHA-256 `afd80f87daef7a040afe5deec36df4085007ac5049f1342709f41c6d39d8dd91`.
- Installed broker, backend-policy, account-identity, and broker-client files matched their repository SHA-256 values before the probe.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Account identity | PASS | Each account's broker identity response matched the Unix account under which its request ran. |
| Own-account status and backup-list shape | PASS | Both accounts received valid responses for their own scope. The probe read backup metadata only. |
| Cross-account status and backup targets | PASS | Both directions rejected caller-supplied account targets with `invalid_request`. |
| Root-only fleet operation | PASS | Both non-root account contexts received `not_authorized` for the reseller fleet operation. |
| Resource boundary | PASS | The fixture account had a temporary ORM-managed Valkey instance; the second account remained `not_configured`. No Redis keys or backup contents were read. |
| Cleanup | PASS | The temporary Valkey instance, account configuration/data directories, backend selector, and uploaded harness were removed. Both accounts returned to `not_configured`; fleet inventory reported zero managed instances and `partial=false`; instance and metrics units were inactive. |
| EA Podman | NOT RUN | No Podman operation was issued by this probe. |
| cPanel UI route and live WHM ACL | NOT RUN | This test exercises the broker through each account's Unix identity; it does not test authenticated web-route isolation or WHM ACL enforcement. |

## Installed source match

The following installed files matched this repository commit before the test:

| Repository file | SHA-256 |
|---|---|
| `src/Orm/Broker/Handler.pm` | `37a338f24a44d0afbd4db4524a2456ae566816a12a64fc035f94d94f0dc0b2a5` |
| `src/Orm/Broker/Protocol.pm` | `703ea347efc09a7033e9f22023e7244685ecbae98aa7508cea1c7967b5145a02` |
| `src/Orm/Broker/InstanceManager.pm` | `106731078e6cb4c5cff0974f54b708672f2dc365d753af9289618f418b4151bd` |
| `src/Orm/Broker/BackendPolicy.pm` | `9f11ac56c39a037c1fe3873c810579755e30fcc0da5e63d374d5c0582b72e9c6` |
| `src/Orm/Backend/BackendPolicyStore.php` | `3aae831570eefe67342ba82a05e6b74a3edab00982b6279e1111c7cedef449f8` |
| `src/Orm/Cpanel/BrokerIdentityVerifier.php` | `fbbd56792d04ac2b21d63b6ab264d561afad332a67cb79272c370cb26c1eac37` |
| `src/Orm/Cpanel/BrokerClient.php` | `671454064edf267c4ad8ab3d03f60d40401776ecea81fe96438b7121c2e6dcf7` |

## Result

Two-account broker identity, resource isolation, target-denial, and root-only authorization checks passed on one source-matched disposable cPanel host. This does not establish production support or complete the wider release gate. Direct cPanel web-route isolation, live WHM ACL checks, all state-changing route CSRF checks, install/uninstall lifecycle validation, and the supported host matrix remain open.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, session URLs, private keys, tokens, and raw server output.
