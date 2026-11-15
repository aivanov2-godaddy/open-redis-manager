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
- Validate ports, memory limits, database counts, eviction policies, package IDs and backend identifiers against allowlists and provider limits.
- Store credentials with restrictive permissions and display them masked. Keep secrets out of logs, audit payloads, diagnostics and support exports.
- Rate-limit authentication-sensitive and expensive operations. Record denial and failure reasons without credential values.
- Score memory use, client counts, evictions and operation rates as signals; report-only must be the initial mode, with warning or enforcement enabled only by scoped provider policy.
- Protect AUTH from repeated failures with bounded rate limiting/lockout, detect weak or reused credentials without printing them, and preserve the previous working credential if rotation verification fails.
- Audit root actions, credential rotation, restore, recovery, backend changes and policy changes.
- Perform backup, validation and rollback before operations that can interrupt a running service or replace data.

## Data handling

Metrics should be aggregated and retained only as long as the provider configures. Diagnostics should state their included fields and redact passwords, authorization headers, private keys, session IDs and user application content. No licensing or telemetry endpoint is required for the open-source core.

The reference product also describes signed commercial licensing and billing lifecycle automation. ORM keeps licensing optional and outside the service-control core; neither commercial licensing nor WHMCS automation is implemented.

## Implemented lifecycle boundary

The browser prototype renders sample data. The installed cPanel page obtains the username from LiveAPI and cross-checks it with a local broker. The broker reads the connecting process UID from Linux `SO_PEERCRED`, maps it through the system account database, and accepts only a matching root-owned cPanel account record. Its fixed operation set provides identity, instance status, live metrics, provision, start and stop. Requests never contain usernames, paths, commands or backend IDs; initial provisioning can carry only a fixed preset ID. Clients close the request half of the socket before the broker dispatches one complete frame.

WHM writes the selected Redis or Valkey backend to a root-owned policy file. The broker derives all instance paths from the authenticated peer account, writes root-owned configuration and metadata, and starts only `orm-instance@<account>.service`. The systemd template runs the server as that cPanel account, allows only Unix-domain sockets, applies resource limits, and grants write access only to that account's mode-0700 data directory. The Redis-compatible process has TCP disabled, no password because its socket is account-private, and persistence disabled by default. Uninstall refuses to remove ORM when any instance metadata remains.

The WHM fleet inventory is a separate read-only broker operation. The broker permits it only for a peer with UID 0, enumerates validated ORM metadata directories, resolves each name through the system account database and trusted cPanel account file, and reuses instance manifest validation before reporting normalized service state. Responses include only account names and states, with fixed-size pagination; submitted identities, paths, commands, or service names are not accepted.

Mutations require POST requests on a `cpsess`-tokenized route, which cPanel/cpsrvd validates before executing the page; the application guard rejects missing or malformed tokenized routes. Initial setup presets and current live metrics are implemented. Existing-instance configuration editing, credentials, metric history, backups, restore, migration, and broad fleet controls are not implemented. The lifecycle, metrics and fleet slices pass Linux CI; disposable live cPanel validation is still required before they can be treated as production-ready. The existing live smoke result verifies only account identity, not provisioning or service behavior.

The broker uses Linux's `SO_PEERCRED` Unix-socket option to read the peer credentials ([`unix(7)`](https://man7.org/linux/man-pages/man7/unix.7.html)). Its systemd unit uses a private runtime directory and filesystem restrictions ([`systemd.exec`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)).
