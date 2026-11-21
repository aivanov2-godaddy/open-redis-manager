# Audit cPanel account lifecycle operations

**Milestone:** 0.2.0 — Operations and lifecycle completeness

## Goal

Include ORM-managed cPanel account provisioning, configuration, start, and stop actions in the normalized WHM audit view.

## Acceptance criteria

- Log only fixed account mutation action names from broker requests whose peer UID resolved to the same cPanel account.
- Record the kernel-derived actor UID, resolved account, fixed action, normalized success/failure, and allowlisted resulting state in `authpriv` under `orm-broker`.
- Never log request payloads, configuration values, presets, AUTH secrets, backup identifiers, Redis output, or raw errors.
- Keep existing AUTH, restore, and root WHM event records compatible; avoid duplicate audit rows for those operations.
- Add the new account event schema to the bounded WHM audit reader and action filter.
- Test successful and failed account actions, unrecognized rows, metadata-only export, and no audit events for read-only requests.
- Update the audit guide, security model, feature catalog, release notes, and sanitized sample screenshot if the UI changes.

## Safety boundary

This event stream is best-effort and bounded by host journal retention. It does not claim to audit cPanel's own Podman commands or provide a complete host audit trail.
