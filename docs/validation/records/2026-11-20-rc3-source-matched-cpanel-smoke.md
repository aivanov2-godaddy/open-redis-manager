# Source-matched ORM rc.3 update and cPanel smoke — 2026-11-20

## Test identity

- Signed release source commit: `87331b0cc0094d8d2de1cf70dc0acdfc39cc1b91` (PR #140).
- Source package changes include the merged Jupiter sprite/cache synchronization fix (PR #139).
- Host purpose: owner-designated disposable cPanel test system.
- Operating system: AlmaLinux 10.3.
- cPanel & WHM: 11.138.0.27, RELEASE tier.
- Installed ORM version before update: `0.1.0-rc.2`.
- Candidate ORM version: `0.1.0-rc.3`.
- Signing: a temporary 3072-bit test-only key was used outside the repository. Only its public key was staged in a root-only temporary trust directory; no production key was used.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| Signed source and artifact verification | PASS | The bundle signature, artifact digest, compatibility range, no-migration declaration, and exact source commit verified. The bundle was built from a clean worktree at the merged commit. |
| Read-only installed-file preview | PASS | Preview reported 48 unchanged records and 3 replacement actions, with zero additions, adoptions, normalizations, conflicts, moves, or retirements. The actions were the package library, package version, and registered WHM AppConfig. |
| Signed apply | PASS | The updater changed the package library and version to `0.1.0-rc.3`. It intentionally preserved the cPanel-normalized WHM AppConfig registration file; that file is not rewritten by the no-migration updater. The v3 manifest, WHM registration, broker service state, and active socket readiness were verified afterward. |
| cPanel page source | PASS | The installed Jupiter entry point matched the signed source package by SHA-256 after update. |
| Authenticated page identity | PASS | The current smoke harness created a temporary cPanel SSO session and verified the page's LiveAPI identity against the selected account. |
| Query-parameter spoof resistance | PASS | A read-only request setting `user`, `username`, and `account` to `root` did not change the SSO-selected account identity. |
| Existing EA Podman Redis discovery | PASS | The authenticated page reported the account-owned socket reachable through its bounded read-only PING check. No keys or values were accessed. |
| Instance data and backend state | PASS | The updater reported that Redis/Valkey instance data and backend selection were unchanged. The smoke performed no lifecycle, configuration, or data operation. |
| Browser screenshot | NOT RUN | The smoke validated the authenticated HTTP response but did not capture or visually inspect an authenticated browser session. |

## Result and limitations

- The current signed rc.3 package update and authenticated cPanel identity, query-spoof, and read-only EA Podman checks passed on this one host.
- This does not establish fresh install, two-account resource isolation, WHM ACL behavior, web-form POST lifecycle controls, backups, restore, migration, recovery, uninstall, AUTH behavior, CloudLinux/CageFS/PHP Selector compatibility, or a supported host matrix.
- The registered WHM AppConfig is preserved by the signed no-migration updater; this test does not claim that registration file was rewritten to the current checkout.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record contains no hostname, IP address, domain, account name, container identifier, socket path, credentials, API tokens, session URL, private key material, key/value data, or raw command output.
