# Live cPanel RC12 update and early POST denial — 2026-11-21

## Test identity

- ORM candidate: `0.1.0-rc.12`.
- Signed source commit: `16267b29ad830ca5fa40538cea9a2412bc254e28`, merged by PR #216 as `720ae8edcffb57cf6a8dd7e3ae547a8854f2ddac`. The release source tree matched the merged tree.
- Candidate artifact SHA-256: `4fb5ba6f6e9c5a0225b065195a51b7fb2f594f275b19ea1a2b1e2645151de7b2`.
- Test date (UTC): 2026-11-21.
- Host purpose: owner-designated disposable cPanel test system.
- Platform: AlmaLinux 10.3; cPanel & WHM 138.0 RELEASE build 27; systemd 257.
- Runtime exercised: cPanel EA PHP 8.5 CLI only for direct entry-point guard probes. No web PHP handler or browser session was exercised.
- Account names, domains, hostnames, addresses, credentials, and session data are omitted.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Candidate signature and source | PASS | The release metadata and archive verified with a temporary RSA-SHA256 test key. Its private key remained on the workstation and was not included in the repo or transferred to the server. The source tree matched the reviewed PR merge tree. |
| Read-only update preview | PASS | Six package files were marked for replacement, 60 were unchanged, with zero conflicts, moves, retirements, or state migrations. The signed source version was `0.1.0-rc.12`; the installed version was `0.1.0-rc.10`. |
| Signed update transaction | PASS | The official apply transaction advanced the install manifest and package to RC12, verified WHM registration and broker socket readiness, and reported that Redis/Valkey data and backend selection were unchanged. The instance systemd unit changed, so the active broker was stopped after confirming zero established clients, then restarted and verified active/enabled. |
| cPanel early POST denial | PASS | The installed cPanel entry point was invoked with EA PHP 8.5 CLI using a POST request, an un-tokenized URI, and a provisioning action. Its early guard returned HTTP 403 before the cPanel API was initialized. No state changed. |
| WHM early POST denial | PASS | The installed WHM entry point was invoked with EA PHP 8.5 CLI using a POST request, an un-tokenized URI, and a backend-selection action. Its early guard returned HTTP 403 before the WHM API was initialized. No state changed. |
| Redis/Valkey state preservation | PASS | The account-owned EA Podman inventory remained one container with a matching before/after inventory digest. There were zero ORM-managed instance directories before and after. No Redis/Valkey keys or values were read or modified. |
| Server-side temporary validation material | PASS | The temporary public trust key, candidate bundle, extracted source, preview output, and transfer archive were removed from the server. The private signing key was never transferred to the server or repository. |

## Scope and limitations

This verifies a signed file update and direct CLI execution of the RC12 cPanel/WHM early-denial guards on one disposable host. It does not exercise browser SSO, a valid-token state-changing action, account creation, the cPanel web handler, or the broader install/uninstall and supported-host matrix. The direct CLI probe verifies the application guard; cPanel `cpsrvd` remains responsible for validating the cryptographic session token on live requests.

An initial apply invocation used an incorrect optional-argument position and was rejected before changing package files. The broker was restored to active/enabled state, and the corrected invocation passed. No Redis/Valkey data or backend state changed.

The one-time private signing key and candidate bundle remain in an ACL-restricted workstation temporary directory because the local execution policy rejected the cleanup command. The public key was removed from the server, and the temporary key was never committed or uploaded.

Overall result: PASS for the stated scenarios. ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, session URLs, private key material, and raw operational output. The temporary release public key was removed from the server after the update.
