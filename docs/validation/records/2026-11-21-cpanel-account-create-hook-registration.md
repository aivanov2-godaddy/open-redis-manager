# Live cPanel account-create hook registration — 2026-11-21

## Test identity

- ORM candidate: `0.1.0-rc.10`, source commit `f596c0b922deac1e7ccb73704b63bddfcb42472c`.
- Platform: AlmaLinux 10.3, cPanel & WHM 11.138.0.27, RELEASE tier.
- Host purpose: owner-designated disposable cPanel test system.
- Account names, domains, hostnames, addresses, credentials, and session data are intentionally omitted.

## Results

| Scenario | Result | Sanitized observation |
|---|---|---|
| Candidate verification | PASS | The temporary test signing key verified the release metadata and artifact digest on the host. The private key stayed on the workstation and was never transferred to the host or repository. |
| Preview | PASS | Three reviewed file replacements, 63 unchanged files, zero conflicts, and no state migrations. |
| Signed update | PASS | RC10 applied over RC9. The updater reported that package files, version, WHM registration, broker state, and socket readiness were verified; Redis/Valkey instance data and backend selection were not changed. |
| Installer verification | PASS | Running `packaging/install.sh` from the exact signed candidate reported that the package already matched and hook registration was verified. |
| cPanel hook registry | PASS | `manage_hooks list` contained exactly one `Whostmgr::Accounts::Create` post script action ending in `--run`; no duplicate was added. |
| Broker state | PASS | The broker was active and enabled after the update and installer checks. |
| Temporary test files | PASS | Candidate bundle, test public key, extracted source, and preview output were removed from the host after validation. |

## Scope and limitations

This verifies signed installation update and idempotent verification of the live cPanel hook registration on one disposable host. It does not exercise creation of a new cPanel account, automatic provisioning under provider policy, a broader host matrix, or production support. No Redis/Valkey package policy, instance, configuration, or data was changed during this test.
