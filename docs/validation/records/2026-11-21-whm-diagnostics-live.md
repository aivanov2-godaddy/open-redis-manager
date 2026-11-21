# Live WHM diagnostics validation — 2026-11-21

## Scope and source identity

- Repository commit: `9ef35b7888f83b945ba4bc669c664547c3d57bac` (merged `main`).
- Installed ORM candidate: `0.1.0-rc.8`.
- cPanel & WHM release: `138.0 (build 27)`.
- Test environment: owner-designated disposable cPanel system; the server and account identifiers are intentionally omitted.
- Candidate review: the installed signed-release preview accepted the exact-source candidate with four replacements, 56 unchanged files, and no conflicts. The signed apply completed and installed the matching source commit.

## Live results

The root-only WHM form was opened through an authenticated cPanel-created SSO session. The source-matched live harness was verified by SHA-256 before it ran; it emitted only pass/fail output and did not retain page bodies or diagnostic values.

| Scenario | Result | Evidence |
|---|---|---|
| Root WHM form | PASS | Authenticated SSO rendered the root diagnostic controls. |
| PING | PASS | Bounded result rendered; `diagnostics.ping` success audit event was recorded. |
| INFO server | PASS | Bounded result rendered; `diagnostics.info_server` success audit event was recorded. |
| INFO memory | PASS | Bounded result rendered; `diagnostics.info_memory` success audit event was recorded. |
| INFO clients | PASS | Bounded result rendered; `diagnostics.info_clients` success audit event was recorded. |
| INFO stats | PASS | Bounded result rendered; `diagnostics.info_stats` success audit event was recorded. |
| DBSIZE | PASS | Bounded result rendered; `diagnostics.dbsize` success audit event was recorded. |
| Rapid repeat | PASS | Each immediate repeat was throttled and its per-class rate-limit audit event was verified. |
| Unsupported class | PASS | `flushall` was rejected by the WHM request flow and produced no diagnostic result. |
| Existing EA Podman Redis | PRESERVED | Rechecked after test cleanup under the test account; its existing Redis container remained present. |
| Temporary direct ORM instance | REMOVED | Its test-created service, configuration, metrics, and data paths were removed after validation. |
| Backend selection and staged update | RESTORED | The temporary backend selection was cleared; all three staged release files match the saved pre-test hashes. |

The reusable harness is [`tests/whm-live-diagnostics-form.php`](../../../tests/whm-live-diagnostics-form.php). The verified harness SHA-256 was `7bb8626a4ed6e8342858e62414480c9571e12d62bca41ef619f9533f56c86864`.

## Evidence limits and remaining work

This confirms the fixed read-only WHM diagnostics on one cPanel release and one disposable ORM-managed Redis instance. It does not establish the supported-host matrix or a production support decision; **ORM support remains NOT ESTABLISHED**.

The live WHM diagnostics table was captured after provisioning a temporary Valkey instance for the test account. The screenshot shows the diagnostic selector and controls only; the account label is redacted and other fleet rows are hidden. See [`whm-diagnostics-live.png`](../../../screenshots/validation/whm-diagnostics-live.png). The temporary service, account configuration/data/metrics, and backend selector were removed or restored after capture, and the existing EA Podman container was confirmed present.

The existing synthetic preview [`screenshots/whm-fleet-diagnostics.png`](../../../screenshots/whm-fleet-diagnostics.png) remains a separate design artifact and is not used as live evidence.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, credentials, SSO URLs/cookies, Redis values, raw response bodies, and raw operational logs. The screenshot contains one test row with its account label redacted; it exposes no host, domain, address, or session data. The temporary signing private key was never copied to the server or repository. The test public key and temporary server-side validation files were removed after restoring the saved update staging.
