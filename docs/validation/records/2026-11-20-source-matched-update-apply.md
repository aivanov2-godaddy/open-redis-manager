# Source-matched signed-update preview and apply — 2026-11-20

## Test identity

- ORM source commit: `a9fd30c072af4ac0b843256d2fc780a087c9b595` (PR #137).
- Test date: 2026-11-20 UTC.
- Host purpose: owner-designated cPanel test system.
- OS and cPanel: AlmaLinux 10.3; cPanel & WHM 138.0 RELEASE build 27.
- Installed ORM version before test: `0.1.0-rc.1`.
- Candidate ORM version: `0.1.0-rc.2`.
- Signing: a temporary test-only key was used outside the repository. It was not a production release key.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Signed source and artifact verification | PASS | The merged source tools verified the candidate signature, archive digest, compatibility range, and exact source commit. |
| Read-only installed-file preview | PASS | Preview reported 2 additions, 18 replacements, 30 unchanged files, and 1 review-required normalization. It reported zero conflicts, moves, and retirements. The normalization was limited to CRLF line endings in the root-owned, correctly permissioned `application_discovery` file; all other bytes matched the signed source after CRLF-to-LF conversion. |
| Signed apply | PASS | The transaction applied the signed candidate and advanced the v3 install manifest to `0.1.0-rc.2`. The normalized installed source matched the signed package byte-for-byte. WHM registration, managed-file integrity, broker service state, and active broker socket readiness passed the updater's post-apply checks. |
| Redis/Valkey data and backend state | PASS | The updater reported that instance data and backend selection were unchanged. A before/after EA Podman container-inventory digest also matched. |
| Interrupted recovery on the live host | NOT RUN | The live transaction completed. The independent Linux CI fixture exercised process interruption, recovery preview, rollback, and exact restoration of the original CRLF bytes. |
| Browser session and full product behavior | NOT RUN | This run validates the signed-update path only; it does not validate the authenticated cPanel page, broader account isolation, backup/restore, migration, or production support. |

## Result

- Overall result: signed source-matched preview and apply passed on this test host.
- Follow-up: retain the broader OS/cPanel/PHP and feature validation gates in issue #7. Do not advertise the host combination or ORM generally as production-supported based on this updater test.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, session URLs, private key material, and raw operational output. The test signing key was temporary and was not added to the repository.
