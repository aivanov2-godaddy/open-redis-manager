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

- The current lifecycle branch wires cPanel status, initialize, start, and stop to fixed broker operations. Account identity is derived from the socket peer UID, and the cPanel request accepts no account ID or configuration payload.
- The page uses cPanel's session-tokenized POST route. Connection details, configuration, presets, metrics, and application integration remain future work.
