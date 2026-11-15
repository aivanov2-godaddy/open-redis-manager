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
- Audit root actions, credential rotation, restore, recovery, backend changes and policy changes.
- Use report-only resource abuse detection as the initial mode; make warning/enforcement explicit, scoped and reversible.
- Perform backup, validation and rollback before operations that can interrupt a running service or replace data.

## Data handling

Metrics should be aggregated and retained only as long as the provider configures. Diagnostics should state their included fields and redact passwords, authorization headers, private keys, session IDs and user application content. No licensing or telemetry endpoint is required for the open-source core.

## Prototype boundary

The current demo renders sample data and does not authenticate users or operate host services. It must not be used as a security boundary or installed as a privileged plugin.
