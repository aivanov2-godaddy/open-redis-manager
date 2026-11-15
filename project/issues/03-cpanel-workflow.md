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
- The page uses cPanel's session-tokenized POST route and shows the account-private socket path, default database, authentication mode, PHP, Node.js, and Python examples with copy controls, live metrics, and five server-allowlisted setup presets. Presets currently apply only during initial provisioning; existing-instance edits, package/reseller ceilings, password management, and framework-specific application helpers remain future work.
- Linux CI passes; live lifecycle actions still need verification on a disposable cPanel host.
