# WHM administrator guide

> This guide describes planned WHM workflows; the local prototype does not control a server.

## Dashboard and accounts

Show managed/running/stopped instances, aggregate memory and connections, backend health and recent alerts. Account search and filters should expose per-account status, port, memory, clients and health. Actions must target one selected account and report a structured result.

## Admin surfaces

- **Redis CLI:** default to a small set of read-only diagnostics. Never pass arbitrary submitted text to a shell. Apply explicit ACL checks and audit command classes.
- **Backups:** support a selected account and optional fleet run with per-account results and retention visibility.
- **Recovery:** scan first; list affected accounts; let the admin repair only selected accounts; audit every change.
- **Backend settings:** show detected Redis/Valkey server and CLI tools, services, versions and managed counts. Readiness checks do not start a migration.
- **Provider settings:** configure report/warn/enforce, UI exposure, defaults, package ceilings and reseller quotas. Enforcement begins with new provisioning.
- **Security:** surface authentication, credential hygiene and resource use as actionable review items.
- **Branding:** preview the account-facing product name, logo, support URL and colors.
- **Updates:** show the source version and release information; preserve existing instances and data.
- **Audit:** filter operational events by time, actor, target and result; never include secrets.

## Authorization

Protect WHM routes with dedicated ACLs. Re-check identity and permission on every state change. A hidden button is not authorization. Refer to the [security model](../security-model.md).
