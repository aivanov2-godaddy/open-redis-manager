# Security model

## Trust boundaries

1. **cPanel user:** may inspect and operate only their own instance and backups.
2. **WHM administrator:** may perform explicitly authorized server-wide operations.
3. **Privileged service:** owns process and configuration changes; it accepts validated structured requests rather than arbitrary command strings.
4. **Redis/Valkey process:** is isolated by account and bound to a private local interface unless a future feature is explicitly designed for remote access.
5. **Provider integrations:** receive minimal, signed events and cannot control the plugin by default.

## Required controls

- Enforce cPanel account identity server-side on every read and write; never trust a submitted username.
- Apply WHM ACL checks and CSRF tokens to all state changes.
- Invoke fixed executable paths with argument arrays; do not concatenate shell commands from request values.
- Validate ports, memory limits, database counts, eviction policies, package IDs and backend identifiers against allowlists and provider limits. Current cPanel memory, client and timeout ranges are broker-enforced request bounds, not package/reseller ceilings.
- Store credentials with restrictive permissions and display them masked. Keep secrets out of logs, audit payloads, diagnostics and support exports.
- Rate-limit authentication-sensitive and expensive operations. Record denial and failure reasons without credential values.
- Score memory use, client counts, evictions and operation rates as signals; report-only must be the initial mode, with warning or enforcement enabled only by scoped provider policy.
- Protect AUTH from repeated failures with bounded rate limiting/lockout, detect weak or reused credentials without printing them, and preserve the previous working credential if rotation verification fails.
- Audit root actions, credential rotation, restore, recovery, backend changes and policy changes.
- Perform backup, validation and rollback before operations that can interrupt a running service or replace data.

## Data handling

Metrics are limited to the latest numeric sample, stored in a root-owned `0600` file for at most 30 days; account users cannot read or modify the snapshot. Diagnostics should state their included fields and redact passwords, authorization headers, private keys, session IDs and user application content. No licensing or telemetry endpoint is required for the open-source core.

The reference product also describes signed commercial licensing and billing lifecycle automation. ORM keeps licensing optional and outside the service-control core; neither commercial licensing nor WHMCS automation is implemented.

## Implemented lifecycle boundary

The browser prototype renders sample data. The installed cPanel page obtains the username from LiveAPI and cross-checks it with a local broker. The broker reads the connecting process UID from Linux `SO_PEERCRED`, maps it through the system account database, and accepts only a matching root-owned cPanel account record. Its fixed operation set provides identity, instance status, live metrics, provision, bounded configuration, start/stop, and account-scoped backup list/create. Requests never contain usernames, paths, commands or backend IDs; initial provisioning can carry only a fixed preset ID and configuration changes carry a strict typed schema. Clients close the request half of the socket before the broker dispatches one complete frame.

WHM writes the selected Redis or Valkey backend to a root-owned policy file. The broker derives all instance paths from the authenticated peer account, writes root-owned configuration and metadata, and starts only `orm-instance@<account>.service`. The systemd template runs the server as that cPanel account, allows only Unix-domain sockets, applies resource limits, and grants write access only to that account's mode-0700 data directory. The Redis-compatible process has TCP disabled, no password because its socket is account-private, and persistence disabled by default. Explicit snapshots are created by the root broker in `/var/lib/orm-instances/.orm-backups`: the shared directory is root-owned mode `0711`, each account directory is root-owned with that account's group and mode `0750`, and snapshot files are root-owned with that group and mode `0640`. The account can list and read its files but cannot replace them or modify the shared namespace. Uninstall refuses to remove ORM when any instance metadata or backup remains.

The account owns its Redis-compatible process and can issue Redis commands through its own private socket. The cPanel form and broker constrain saved ORM settings, but they do not prevent an account from changing its own runtime values directly; those runtime changes may differ from the root-owned config file until the service restarts. The systemd unit's 96 MiB memory limit and 256 file-descriptor limit remain operating-system backstops. Package/reseller enforcement is not implemented.

The WHM fleet inventory is root-only. The broker enumerates validated ORM metadata directories, resolves each name through the system account database and trusted cPanel account file, and reuses manifest validation before reporting normalized state. A separate root-only control operation accepts only a validated account name and `start`, `stop`, or `restart`; it resolves the peer-selected target against trusted cPanel metadata, validates the instance manifest, and maps the action to the manager's fixed systemd calls. It writes actor UID, target account, action class, result and normalized state to syslog's `authpriv` facility without command output or credentials. Denied non-root attempts use the kernel peer UID and the same facility. Responses contain only the target name, action, normalized state and audit-write status. Non-root peers cannot invoke the operation.

Mutations require POST requests on a ten-digit `cpsess`-tokenized route, which cPanel/cpsrvd validates before executing the page; the application guard rejects missing or malformed tokenized routes. Initial setup presets, bounded existing-instance configuration, live/stale latest-sample metrics, root-only per-account WHM start/stop/restart, and account-scoped RDB snapshot creation/list/download with three-item retention are implemented. Credentials, metric history, backup restore, migration, recovery and broad fleet controls are not implemented. The backup client runs only a fixed discovered executable with argument-array inputs, a 60-second deadline, and a 128 MiB output ceiling; command output is discarded. Disposable live cPanel validation remains required before production use.

The broker uses Linux's `SO_PEERCRED` Unix-socket option to read the peer credentials ([`unix(7)`](https://man7.org/linux/man-pages/man7/unix.7.html)). Its systemd unit uses a private runtime directory and filesystem restrictions ([`systemd.exec`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)).
