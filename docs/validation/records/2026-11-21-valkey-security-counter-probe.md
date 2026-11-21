# Valkey security-counter field probe — 2026-11-21

## Test identity

- Target: owner-designated cPanel test system; host, account, and domain identifiers are omitted.
- Backend binary: standalone Valkey server and CLI, version `8.1.10`.
- Operation: started a temporary isolated server with TCP disabled and a private Unix socket, then requested `PING`, `INFO server`, and `INFO stats`.
- Data scope: no keys, values, credentials, or counter values were retained.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Valkey server version | PASS | `valkey_version=8.1.10`. |
| Eviction counter field availability | PASS | `evicted_keys` was present in `INFO stats`; its value was not recorded. |
| Processed-command counter field availability | PASS | `total_commands_processed` was present in `INFO stats`; its value was not recorded. |
| Optional authentication-failure counter availability | PASS | `acl_access_denied_auth` was present in `INFO stats`; its value was not recorded. |
| ORM collection and WHM report | NOT RUN | This direct binary probe did not exercise cPanel EA Podman, ORM collection, or the WHM report page. |

## Result and limits

- The standalone Valkey 8.1.10 binary exposes all three field names used by ORM's security counter sampler.
- This is field-availability evidence for one Valkey version, not an end-to-end ORM test or a compatibility guarantee for other Valkey releases. The security-report fixture suite separately exercises Valkey counter collection and the missing optional-auth-field path.
- ORM support decision: `NOT ESTABLISHED`.

## Cleanup and sanitization

The temporary server was shut down with `SHUTDOWN NOSAVE`. A follow-up check found no probe process or temporary probe directory. No hostnames, IP addresses, domains, account names, socket paths, credentials, private keys, raw INFO output, counter values, keys, or payloads are included here.
