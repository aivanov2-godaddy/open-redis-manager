# Live cPanel Podman discovery smoke — 2026-11-20

## Test scope

- Host purpose: owner-designated disposable cPanel test system.
- Test identity: one authenticated cPanel account with an existing EA Podman Redis socket; the account name and socket path are intentionally omitted.
- OS, cPanel & WHM version/tier, architecture, and PHP handler: not recaptured in this run.
- The default live smoke verifies the LiveAPI username against the local broker. The opt-in `--require-podman-cache` assertion also requires the authenticated page to show a reachable cPanel-managed socket.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| cPanel account identity | PASS | The authenticated page passed the existing LiveAPI-to-broker identity check. |
| Account-owned Podman discovery | PASS | The account page rendered the existing cPanel-managed Redis socket under its Podman section. |
| Read-only health probe | PASS | The cPanel internal PHP runtime did not provide PhpRedis, so the candidate used the fixed RESP `PING` fallback and the page reported the socket reachable. The fallback reads only the PING response and does not inspect keys, values, or credentials. |
| Cache lifecycle or data operations | NOT RUN | The smoke did not create, stop, reconfigure, or write to the container or its data. |

## Reversible candidate deployment

- Before the live run, the prior cPanel page and `PodmanCacheDiscovery.php` were copied to a root-only temporary backup. The candidate versions were installed with root ownership and mode `0644` for the smoke.
- The live assertion passed. Both original files were then restored and byte-compared with their temporary backups; the uploaded test files and backup directory were removed.
- No package manifest, ORM service, broker state, Podman container, cache data, or account configuration was changed by the test.

## Result and limitations

- This proves the candidate page can discover and perform a bounded read-only PING against one account-owned EA Podman Redis socket on one test host.
- It does not establish Redis/Valkey version support, PhpRedis client behavior for applications, service lifecycle safety, cross-account denial across multiple accounts, or a supported cPanel/OS matrix.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits hostnames, IP addresses, domains, account names, container identifiers, socket paths, credentials, tokens, session URLs, keys, values, and raw logs.
