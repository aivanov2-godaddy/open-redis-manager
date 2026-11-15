# Account instance lifecycle

## Current behavior

The installed cPanel page supports inspect state, read live metrics, initialize, configure bounded settings, start, and stop for the signed-in account. WHM must first select an installed Redis or Valkey server as the default backend for new ORM instances. The backend choice is stored in a root-owned policy file and does not change existing services.

Each browser request is cross-checked against the local broker. The broker derives the target account from the kernel-supplied Unix peer UID and the trusted cPanel account record. Requests contain no username, path, unit, command, port, or arbitrary configuration values. Initial provisioning may carry only one of five fixed preset IDs; configuration requests carry four typed, bounded fields from a fixed schema. The client sends one newline-terminated frame and closes its write side before dispatch. Mutating requests are rate-limited.

On initialization, ORM creates a per-account service using `orm-instance@<account>.service`. The service runs under that cPanel account and uses a private Unix socket inside the account's mode-0700 data directory. Redis/Valkey TCP access is disabled. The selected cPanel setup preset sets `maxmemory` from the server-side allowlist (32, 48, or 64 MiB); all profiles use 16 logical databases, 100 clients, `allkeys-lru`, and no automatic RDB or AOF persistence. Existing settings can be changed within fixed bounds: 8–64 MiB, an allowlisted eviction policy, 10–100 clients, and a 0–300 second idle timeout. Running services receive fixed per-setting `CONFIG SET` calls without restart; the broker then atomically saves its generated config. Stopped or failed services save changes for the next start. Reducing memory can immediately evict keys. The systemd unit applies separate process memory, CPU, task and file-descriptor limits. The root-owned manifest records the initial preset; older version 1 manifests are treated as Generic.

For every configured instance, the page requests a read-only metric sample through the local broker. The broker derives the account and socket from peer credentials and its root-owned manifest, runs the fixed backend CLI with an argument vector, and returns only numeric used/peak memory, connected clients, uptime, operations per second, and keyspace hits/misses, plus a capture time, stale flag, and whether the live sample was retained. The command has a three-second deadline and bounded output; no command names, keys, credentials, or raw INFO text reach the browser. The broker atomically retains only the latest successful sample as root-owned mode `0600` metadata next to the account manifest. If the service is stopped or the live probe fails, a valid sample no older than 30 days is returned with a stale marker. Invalid or expired snapshots are never displayed; expired snapshots are removed when requested. If writing a fresh snapshot fails, the live values are still returned and the page states that they could not be saved for fallback. No metric history is stored.

## Security and preservation

- Instance identity and paths come from the broker's `SO_PEERCRED` account mapping; form fields cannot select another account.
- The WHM backend policy and instance manifests are root-owned. Configuration is root-owned and readable by the account group; only the account owns and can access its data directory.
- The launcher accepts only fixed Redis and Valkey binary paths and passes the fixed configuration path as an argument vector without a shell.
- The service uses only `AF_UNIX`, `PrivateNetwork`, strict filesystem protection, and one account-specific writable path.
- Opening the cPanel page only reads status. Start/stop and WHM policy changes are POST-only, require a `cpsess`-tokenized route, and rely on cPanel/cpsrvd to validate the session token.
- Uninstall refuses to remove ORM while entries remain under either managed instance root. It does not delete account data.

## Not implemented yet

The installed cPanel page displays the account's Unix socket path, database 0, connection examples for PhpRedis, node-redis and redis-py, live current metrics while the service runs, and controls for a bounded set of saved configuration values. This build does not configure Redis AUTH or expose a TCP endpoint; access is controlled by the account-owned, mode-0700 socket directory. The account owns its Redis process and can change runtime values through that socket, so broker-saved settings are not package enforcement and direct changes can remain until a restart. Explicit RDB snapshots can be created, listed and downloaded from the cPanel page; ORM keeps the newest three per account. Restore, historical graphs, application discovery, recovery, migration, package/reseller limits, and audit history still need implementation.

## Validation status

Linux CI passed, including the broker tests, packaging root-guard tests, PHP checks, and systemd unit verification. The prior live cPanel smoke test verified only that one authenticated LiveAPI account matched the local broker identity. It did not provision or operate a Redis/Valkey process. A disposable cPanel end-to-end lifecycle test is still required before production use.
