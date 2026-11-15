# Feature catalog

This catalog records the public product behavior observed on the reference site and separates it from what this repository currently implements. Descriptions are summarized in our own words. Source pages and observation limits are in [source notes](../source-notes.md).

## cPanel account experience

| Feature | Expected behavior | Prototype |
|---|---|---|
| Status and lifecycle | Show online, stopped, degraded or unavailable state; initialize, start and stop only the current account instance. | Dashboard and Instance |
| Connection details | Show host, port, database and credential with the secret hidden by default; copy values on explicit request. | Connection |
| Health and preflight | Explain whether an instance exists, is running and has authentication configured; link each warning to a remedy. | Dashboard |
| Metrics | Present memory, peak memory, connected clients, uptime, command rate and hit/miss ratio with a selectable time window. Mark stale samples. | Monitoring |
| Presets | Offer WordPress, Laravel, Magento, session cache and generic starting profiles. Validate every saved setting against provider ceilings. | Configuration |
| Advanced settings | Configure memory ceiling, eviction policy, database count, timeout, clients and persistence when provider exposure allows it. | Configuration |
| Backups and restore | Create account-scoped backups, list retained snapshots, and take a safety snapshot before replacing current data during restore. | Backups |
| Application detection | Detect common app markers without reading secrets or changing files; show an integration status that the user can correct. | Applications |
| Connection helper | Render examples for WordPress, LiteSpeed Cache, Laravel, Magento, plain PHP, Node.js and Python. Mask secrets in generated diagnostics. | Applications |
| Diagnostics export | Download a support bundle with configuration and health context while redacting credentials and private values. | Diagnostics |
| Health guidance | Summarize the state with actionable suggestions for memory pressure, weak cache hit ratio, connection issues and disabled runtime clients. | Dashboard |

## WHM server administration

| Feature | Expected behavior | Prototype |
|---|---|---|
| Fleet dashboard | Summarize managed/running accounts, connections, memory, backend availability and service health. | Overview |
| Account manager | Search and filter accounts by state; inspect usage; start, stop, restart and edit within package limits. | Accounts |
| Backend discovery | Detect Redis and Valkey service, server/CLI binary, version and managed account counts. Explain selection and migration readiness. | Backends |
| Redis command console | Run an allowlisted set of read-only diagnostics against a chosen account, or offer a carefully permissioned admin console with audit. | CLI |
| Backups | Browse account snapshots and request targeted or fleet backups; report partial failures per account. | Backups |
| Recovery | Scan first, repair only affected accounts, rebuild configuration from trusted metadata, fix ownership, rotate credentials, and audit each action. | Recovery |
| Provider policy | Choose report-only, warn or enforce; select Simple, Developer or Advanced exposure; keep grandfathering explicit. | Policies |
| Global defaults | Set memory, eviction, database, backup and history defaults for newly provisioned accounts. | Settings |
| Package limits | Set eligibility, memory/client/database ceilings, backup retention and optional auto-provision behavior per package. | Packages |
| Reseller quotas | Summarize accounts and consumption; cap new instances and aggregate memory without mutating existing services. | Resellers |
| Security | Surface authentication failures, credential hygiene and resource-abuse signals; rotate credentials with rollback-safe sequencing. | Security |
| Branding | Configure provider product name, logo, support link and accessible color palette with live preview. | Branding |
| Updates | Check release metadata and expose an administrator-approved update path that preserves existing accounts. | Updates |
| Audit | Record privileged changes and operation results without secrets; support filtering and export. | Audit |
| Backend migration | Snapshot, switch one account, verify health and connectivity, then roll back on failure. Require explicit confirmation and show downtime/data semantics. | Migration |

## Integrations

See [integration matrix](../integrations.md) for PHP extensions, frameworks, control panels and provider billing events.

## Public roadmap themes captured from the reference

The reference site lists deeper observability and slow-log tools, background workers and auto-healing, cross-server export/import, an API and webhooks, cluster/Sentinel support and another control panel. These are recorded as ideas for independent planning, not commitments or claims that this project has implemented them.
