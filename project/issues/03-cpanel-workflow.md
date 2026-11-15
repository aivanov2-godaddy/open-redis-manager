# Implement cPanel account workflow

## Goal
Connect the cPanel prototype to account-scoped operations and connection guidance.

## Acceptance criteria
- Status, lifecycle, masked credentials, configuration, presets and setup preflight are account-scoped.
- Effective limits reflect package and reseller ceilings.
- Monitoring marks stale samples and retains last-known values.
- Connection helpers cover the integrations in `docs/integrations.md`.
- Application discovery does not modify application files or return secret contents.
- Diagnostics redact credential values.

## Progress

- PR #16 merged cPanel status, initialize, start, and stop through fixed broker operations. Account identity is derived from the socket peer UID, and the cPanel request accepts no account ID or free-form configuration; initial provisioning now accepts only one of five fixed preset IDs.
- A bounded configuration slice adds account-scoped settings for memory, eviction policy, client limit, and idle timeout. Requests use a fixed typed schema; running instances receive per-setting updates and the broker atomically saves generated config without restarting the service.
- The page uses cPanel's session-tokenized POST route and shows the account-private socket path, default database, authentication mode, PHP, Node.js, and Python examples with copy controls, live metrics, five server-allowlisted setup presets, and a limited settings form. Package/reseller ceilings, password management, drift detection, and framework-specific application helpers remain future work. The cPanel account can issue commands against its own socket, so UI/broker settings are not a package-enforcement boundary.
- Linux CI passes; live lifecycle actions still need verification on a disposable cPanel host.
