# Add live account-scoped usage metrics for cPanel EA Podman caches

**Milestone:** 0.2.0 — Operations and lifecycle completeness
**Status:** implementation in review

## Goal

Show current usage for verified Redis and Valkey EA Podman caches owned by the signed-in cPanel account, while cPanel retains container and data ownership.

## Acceptance criteria

- Use a fixed, bounded, read-only PING and INFO request against only the verified account-owned Unix socket.
- Parse only memory used/peak, connected clients, uptime, operations per second, cache hits/misses, and the backend version.
- Display available metrics as a page-load sample; preserve unknown values when fields or the probe are unavailable.
- Do not request Redis keys or values, accept arbitrary commands, retain Podman metrics, or alter container configuration/data.
- Cover parser bounds, allowlisting, malformed numeric values, account ownership, and the no-PhpRedis RESP path with tests.
- Document the behavior and include a synthetic UI preview.

## Validation limits

Automated Linux tests exercise filesystem ownership and Unix-socket protocol behavior. A green CI run does not establish support for every cPanel, PHP, Redis, Valkey, or host combination; live validation remains a separate release gate.
