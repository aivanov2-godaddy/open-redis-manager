# Current-source install and uninstall lifecycle

## Test identity

- ORM commit: `48c111dbc2acf42901ca78c74130c21ff1f32eec`
- Test date (UTC): 2026-11-22
- Host purpose: owner-designated disposable cPanel & WHM test system
- cPanel version and release tier: 138.0 (build 27), RELEASE
- OS name and major version: AlmaLinux 10.3
- Architecture: x86_64
- CloudLinux: absent
- CageFS: `cagefsctl` absent
- ORM package version: `0.1.0-rc.12`

The source archive was built from the clean repository commit, transferred to the test host, and its SHA-256 was verified before extraction. The pre-test installation matched the exact parent revision of this commit; the only difference from the current source was the `packaging/lib.sh` change in PR #225. Its install manifest, WHM registration, account-create hook, empty managed-instance roots, and service state were verified before lifecycle operations.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Fresh install and cPanel/WHM registration | PASS | On current commit `48c111d`, the installer registered the Jupiter cPanel feature and WHM AppConfig, installed the broker and account-create hook, and wrote a valid manifest. A second install returned the verified already-matches result. The current package integrity check passed afterward. |
| Repeated install | PASS | The exact pre-test package's installer returned already-matches twice. The current package's first install completed; its second install returned already-matches. |
| Uninstall and repeated uninstall | PASS | The exact pre-test package was removed with its matching source. The current package was then removed with its matching source. Each second uninstall reported the already-uninstalled state. cPanel and WHM registrations were removed and verified. |
| Reinstall after uninstall | PASS | The current package reinstalled after both uninstalls; a second install verified idempotency. The current install manifest, installed-file set, WHM registration, account-create hook, and active broker state were checked. |
| Scheduled service-state preservation | PASS | Provider-event and EA Podman metrics timers were disabled/inactive before and after the lifecycle cycle. The installer enables them as part of installation; they were disabled and their services stopped immediately after each install to restore the test baseline. |
| Existing Redis/Valkey and EA Podman data | PASS | No ORM-managed instances existed before or after. The existing EA Podman container-directory count remained two. Provider-event configuration remained present; its values were not read. The aggregate Podman snapshot remained absent. No Redis/Valkey service, account container, or user data operation was requested. |
| Account identity and cross-account denial | NOT RUN | This record covers package lifecycle and registration only. |
| Provisioning, backup/restore, migration, AUTH, and recovery | NOT RUN | No ORM-managed instance was created for this test. |
| Browser visual review and supported-host matrix | NOT RUN | This is one installation lifecycle check, not a production support determination. |

## Result

- Overall result: PASS for current-source fresh install, registration, repeated install, uninstall, repeated uninstall, reinstall, and baseline service-state restoration on this single test host.
- Known limitations: upgrade behavior, browser review, live account creation, populated ORM-managed data preservation, service lifecycle, and the broader cPanel/WHM host matrix remain unvalidated by this record.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, session URLs, raw logs, and provider configuration values.
