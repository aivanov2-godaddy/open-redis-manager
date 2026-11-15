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
