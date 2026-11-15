# WHM administrator guide

The installed WHM addon displays detected Redis and Valkey backends and the selected default for new instances. Root WHM administrators also have a paginated view of ORM-managed account names and normalized service states, with per-page search and state filters. Root can request start, stop, or restart for a selected account; the broker separately verifies UID 0, resolves the account from trusted cPanel metadata, validates its manifest, maps the action to a fixed systemd operation, and records actor/account/action/result/state through syslog. Denied non-root attempts are logged with the kernel peer UID. Stop and restart require browser confirmation, and the page reports transitional states such as `starting` or `stopping`.

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

The fleet view is root-only. The WHM application asks the local broker for its inventory; the broker checks the kernel-derived peer UID and accepts the fleet operation only from UID 0. It lists only ORM metadata backed by a matching cPanel account record and valid local account identity. Names and state are escaped before rendering; IDs, paths, configuration, and credentials are omitted. Pagination keeps broker replies within the protocol size limit. Search and state filtering apply to the displayed page.

Fleet controls are root-only and use POST on a WHM `cpsess` route. The broker rejects non-root peers, malformed account names, unknown actions, untrusted account records, and invalid instance manifests before invoking a manager method. Restart is limited to running or starting instances. A missing audit-write confirmation is shown separately from the operation result. The interface does not yet expose the Redis CLI, repair, migration, or per-account configuration. Refer to the [security model](../security-model.md).
