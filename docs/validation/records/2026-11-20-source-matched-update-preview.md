# Source-matched signed-update preview — 2026-11-20

## Test identity

- ORM source commit: `3614c91` (`main`, PR #134).
- Host purpose: owner-designated cPanel test system.
- Installed ORM version: `0.1.0-rc.1`.
- Candidate ORM version: `0.1.0-rc.2`.
- A temporary test signing key was created outside the repository. The candidate artifact digest and signature were verified against the exact source bundle before preview.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Installed preview tool accepts current candidate archive | BLOCKED | The older installed preview tool rejected the newer archive format with `unexpected file is present`; no files were changed. |
| Current-source artifact and signature verification | PASS | The exact `3614c91` source tools verified the candidate metadata, archive digest, and signature. |
| Source-matched update preview | BLOCKED | The preview reported 2 additions, 14 replacements, 34 unchanged files, and one conflict. The existing `application_discovery` file is absent from the installed v3 manifest, so the updater correctly refused to treat it as an ordinary addition. No moves, retirements, or state migrations were proposed. |
| Update apply and package/service state | NOT RUN | Apply was not attempted because the preview had a conflict. The installed ORM package, broker, Redis/Valkey services, and account data were not changed. Existing staged release files were preserved. |

## Result

- Overall result: signed source-matched preview verified, then blocked safely on the unmanifested `application_discovery` file.
- Follow-up: resolve and review the installed manifest discrepancy through a supported migration/reconciliation path before attempting another apply. Do not delete or overwrite the existing file to bypass the conflict.
- Known limitation: this result validates preview behavior only. It does not validate update apply, rollback, source synchronization, or a supported cPanel host matrix.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits the hostname, IP address, domains, account names, credentials, session URLs, private key material, and raw operational output. Temporary signing material and candidate files were removed from the local validation directory after the preview.
