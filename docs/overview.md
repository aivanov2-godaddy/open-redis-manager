# Product overview

Open Redis Manager (ORM) is planned as a cPanel/WHM plugin for provisioning and operating per-account Redis-compatible services. It will support Redis and Valkey behind a backend adapter so a provider can select a backend while applications continue to connect with familiar Redis clients.

## People and surfaces

| Person | Surface | Main tasks |
|---|---|---|
| Website owner | cPanel | Start or stop an isolated cache, copy connection settings, choose a workload preset, view health and metrics, back up data, and connect an application. |
| Hosting administrator | WHM | See fleet health, provision and recover account services, inspect usage, select a backend, set safe limits, and review the audit trail. |
| Hosting provider | WHM provider controls | Define package eligibility, reseller quotas, user-facing detail level, brand settings, and policy mode. |
| Developer | Connection helper | Copy language/framework examples and check that the PHP runtime has a compatible Redis client enabled. |

## Request path

Applications use their Redis client to connect to an account-scoped loopback endpoint. The plugin is responsible for control-plane actions and connection metadata; application code remains responsible for using Redis as a cache, session store, queue, or data service. The plugin must never imply that enabling Redis automatically makes an application cache its data.

## Core entities

- **Account instance:** cPanel account, backend, service identity, port/socket, credential reference, bounded configuration, state and health.
- **Package policy:** eligibility and ceilings for memory, clients, databases and retained backups.
- **Reseller quota:** optional cap for instance count and aggregate memory.
- **Backup:** account-scoped snapshot metadata and restore provenance.
- **Audit event:** actor, action, target, result and timestamp with secrets excluded.
- **Provider settings:** backend preference, enforcement mode, exposure level, defaults and branding.

## Behavioral constraints

- New installations may select a backend from host capabilities and provider policy. An upgrade must preserve the existing backend and account data.
- Policy changes must not silently suspend or rewrite existing accounts. Enforcement applies to new provisioning first; migration or remediation is an explicit administrative action.
- A cache is ephemeral by default. Backups are explicit and separate from Redis persistence settings.
- Monitoring should retain the last known value during a temporary sample failure and identify that value as stale.

## Current implementation status

The PHP demo is a static interaction prototype with sample values. The installed cPanel/WHM entry points can select a backend and provision, inspect, start, stop, and sample current usage for a per-account Redis/Valkey process through a closed local broker. cPanel initialization offers five fixed, server-validated workload presets. Existing-instance configuration editing, credentials, metric history, backup, restore, and migration remain unimplemented. See the [instance lifecycle guide](guides/instance-lifecycle.md) and [feature catalog](features/catalog.md).
