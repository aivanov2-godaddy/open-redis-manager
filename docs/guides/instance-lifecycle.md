# Account instance lifecycle

## Current behavior

The installed cPanel page supports inspect state, read live metrics, initialize, start, and stop for the signed-in account. WHM must first select an installed Redis or Valkey server as the default backend for new ORM instances. The backend choice is stored in a root-owned policy file and does not change existing services.

Each browser request is cross-checked against the local broker. The broker derives the target account from the kernel-supplied Unix peer UID and the trusted cPanel account record. The request protocol is a closed set of fixed operation names; it has no username, path, unit, command, port, or configuration fields. The client sends one newline-terminated frame and closes its write side before dispatch. Mutating requests are rate-limited.

On initialization, ORM creates a per-account service using `orm-instance@<account>.service`. The service runs under that cPanel account and uses a private Unix socket inside the account's mode-0700 data directory. Redis/Valkey TCP access is disabled. The generated starter configuration has a 64 MiB `maxmemory`, 16 logical databases, 100 clients, `allkeys-lru`, and no automatic RDB or AOF persistence. The systemd unit applies separate process memory, CPU, task and file-descriptor limits.

When the instance is running, the page requests a fresh read-only sample through the local broker. The broker derives the account and socket from peer credentials and its root-owned manifest, runs the fixed backend CLI with an argument vector, and returns only numeric used/peak memory, connected clients, uptime, operations per second, and keyspace hits/misses. The command has a three-second deadline and bounded output; no command names, keys, credentials, or raw INFO text reach the browser. If sampling fails, the page marks the current sample unavailable. Samples are not retained, so there is no history or stale-value display yet.

## Security and preservation

- Instance identity and paths come from the broker's `SO_PEERCRED` account mapping; form fields cannot select another account.
- The WHM backend policy and instance manifests are root-owned. Configuration is root-owned and readable by the account group; only the account owns and can access its data directory.
- The launcher accepts only fixed Redis and Valkey binary paths and passes the fixed configuration path as an argument vector without a shell.
- The service uses only `AF_UNIX`, `PrivateNetwork`, strict filesystem protection, and one account-specific writable path.
- Opening the cPanel page only reads status. Start/stop and WHM policy changes are POST-only, require a `cpsess`-tokenized route, and rely on cPanel/cpsrvd to validate the session token.
- Uninstall refuses to remove ORM while entries remain under either managed instance root. It does not delete account data.

## Not implemented yet

The installed cPanel page displays the account's Unix socket path, database 0, connection examples for PhpRedis, node-redis and redis-py, and live current metrics while the service runs. This build does not configure Redis AUTH or expose a TCP endpoint; access is controlled by the account-owned, mode-0700 socket directory. Framework-specific configuration, account configuration editing, historical graphs, application discovery, backups, restore, recovery, migration, package/reseller limits, and audit history still need implementation.

## Validation status

Linux CI passed, including the broker tests, packaging root-guard tests, PHP checks, and systemd unit verification. The prior live cPanel smoke test verified only that one authenticated LiveAPI account matched the local broker identity. It did not provision or operate a Redis/Valkey process. A disposable cPanel end-to-end lifecycle test is still required before production use.
