# Feature catalog

This catalog records the public product behavior observed on the reference site and separates it from what this repository currently implements. Descriptions are summarized in our own words. Source pages and observation limits are in [source notes](../source-notes.md).

## cPanel account experience

| Feature | Expected behavior | Prototype |
|---|---|---|
| Status and lifecycle | Show online, stopped, degraded or unavailable state; initialize, start and stop only the current account instance. | Authenticated cPanel entry point supports backend-gated initialize, status, start and stop through the peer-credential broker, with live metrics and stale fallback. Earlier Linux CI passed; this update requires its own CI run. Live cPanel behavior remains unverified. Uses an account-private Unix socket. |
| Connection details | Show the active endpoint, database and authentication mode; reveal or copy a secret only on explicit request. | The installed cPanel page shows the current account's private Unix socket path, database 0, and PhpRedis, node-redis and redis-py examples with per-example copy buttons. ORM-managed instances do not expose TCP or configure Redis AUTH in this build; secret management remains unimplemented. |
| Health and preflight | Explain whether an instance exists, is running and has authentication configured; link each warning to a remedy. | Dashboard |
| Metrics | Present memory, peak memory, connected clients, uptime, command rate and hit/miss ratio with a selectable time window. Mark stale samples. | The installed cPanel page shows bounded live/latest-known values plus hourly memory, client and hit-ratio charts with 24-hour and 7-day ranges. A per-account systemd timer collects only while the cache is running. Root-owned `0600` history is capped at 720 samples and 30 days; disposable-host validation remains open. |
| Presets | Offer WordPress, Laravel, Magento, session cache and generic starting profiles. Validate every saved setting against provider ceilings. | cPanel initialization offers five fixed presets with server-defined memory values capped at 64 MiB. Values are selected at provisioning only; package/reseller ceilings and changes to existing instances remain unimplemented. |
| Advanced settings | Configure memory ceiling, eviction policy, database count, timeout, clients and persistence when provider exposure allows it. | The cPanel page edits memory (8–64 MiB), an allowlisted eviction policy, maximum clients (10–100), and idle timeout (0–300 seconds) through the account-bound broker. Database count, persistence, and package ceilings remain host-controlled or unimplemented. |
| Backups and restore | Create account-scoped backups, list retained snapshots, and take a safety snapshot before replacing current data during restore. | The installed cPanel page creates, lists, downloads, and restores explicit RDB snapshots for the authenticated account. Restore accepts only a listed opaque ID, validates its RDB, creates a safety snapshot, stops and restarts the service, verifies the active state, and attempts rollback if startup fails. Snapshots are root-controlled, capped at 128 MiB and 60 seconds, and retained to the newest three. WHM fleet backup and restore remain unimplemented; live cPanel validation is still required. |
| Application detection | Detect common app markers without reading secrets or changing files; show an integration status that the user can correct. | Applications |
| Connection helper | Render examples for WordPress, LiteSpeed Cache, Laravel, Magento, plain PHP, Node.js and Python. Mask secrets in generated diagnostics. | The installed cPanel page includes PhpRedis, node-redis and redis-py Unix-socket examples. Framework-specific configuration and diagnostics remain unimplemented. |
| Diagnostics export | Download a support bundle with configuration and health context while redacting credentials and private values. | Diagnostics |
| Health guidance | Summarize the state with actionable suggestions for memory pressure, weak cache hit ratio, connection issues and disabled runtime clients. | Dashboard |
| Safe live configuration | Apply an account-level memory change live where supported; preserve account ownership and report apply failures instead of implying the saved file took effect. | Configuration |
| Authenticated account context | Derive the current account from the cPanel session and use it for all account-scoped reads and writes. | The cPanel page cross-checks the LiveAPI username with the peer-credential broker, and lifecycle operations use that broker-derived account. A single-host identity smoke passed; lifecycle operations and the supported host matrix still need cPanel validation. |

## WHM server administration

| Feature | Expected behavior | Prototype |
|---|---|---|
| Fleet dashboard | Summarize managed/running accounts, connections, memory, backend availability and service health. | The installed WHM page shows a root-only paginated inventory with normalized service states. Aggregate connections, memory and alerts remain unimplemented. |
| Account manager | Search and filter accounts by state; inspect usage; start, stop, restart and edit within package limits. | Root can start, stop and restart a selected validated instance. The broker confirms UID 0, resolves the target account from trusted metadata, validates its manifest, and logs the action result. Search and state filters apply to the current page; per-account usage and package limits remain unimplemented. |
| Backend discovery | Detect Redis and Valkey service, server/CLI binary, version and managed account counts. Explain selection and migration readiness. | WHM displays read-only discovery and lets root WHM select the installed default for future ORM instances; account counts and migration readiness remain unavailable. |
| Redis command console | Run an allowlisted set of read-only diagnostics against a chosen account, or offer a carefully permissioned admin console with audit. | CLI |
| Backups | Browse account snapshots and request targeted or fleet backups; report partial failures per account. | Backups |
| Recovery | Scan first, repair only affected accounts, rebuild configuration from trusted metadata, fix ownership, rotate credentials, and audit each action. | Recovery |
| Provider policy | Choose report-only, warn or enforce; select Simple, Developer or Advanced exposure; keep grandfathering explicit. | Policies |
| Global defaults | Set memory, eviction, database, backup and history defaults for newly provisioned accounts. | Settings |
| Package limits | Set eligibility, memory/client/database ceilings, backup retention and optional auto-provision behavior per package. | Packages |
| Reseller quotas | Summarize accounts and consumption; cap new instances and aggregate memory without mutating existing services. | Resellers |
| Security | Surface authentication failures, credential hygiene and resource-abuse signals; rotate credentials with rollback-safe sequencing. | Security |
| Abuse reports | Score memory, client, eviction, and operation-rate signals; report findings first, with enforcement as a separate explicit policy. | Security |
| Authentication protection | Rate-limit repeated authentication failures, audit lockouts without logging secrets, and detect weak or reused credentials without exposing values. | Security |
| Branding | Configure provider product name, logo, support link and accessible color palette with live preview. | Branding |
| Updates | Check release metadata and expose an administrator-approved update path that preserves existing accounts. | Updates |
| Audit | Record privileged changes and operation results without secrets; support filtering and export. | Audit |
| Backend migration | Snapshot, switch one account, verify health and connectivity, then roll back on failure. Require explicit confirmation and show downtime/data semantics. | Migration |
| Update lifecycle | Show version/release state in WHM, preserve existing account configuration, and verify registration, visibility, health, and reported version after an update. | Updates |

## Integrations

See [integration matrix](../integrations.md) for PHP extensions, frameworks, control panels and provider billing events.

## Public roadmap themes captured from the reference

The reference site lists deeper observability and slow-log tools, background workers and auto-healing, cross-server export/import, an API and webhooks, cluster/Sentinel support and another control panel. These are recorded as ideas for independent planning, not commitments or claims that this project has implemented them.
