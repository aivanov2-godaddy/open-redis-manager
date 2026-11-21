# Reference site: documentation page

**Source:** [cpanelredismanager.com/documentation.php](https://cpanelredismanager.com/documentation.php)
**Observed:** 2026-11-21; the page displayed v2.6.11. The complete accessibility capture and its limits are recorded in the [REA evidence ledger](../rea-evidence.md#read-only-recheck-on-2026-11-21).

## Documentation sections shown

The page is a long-form documentation index covering:

- installation prerequisites and deployment verification;
- upgrade, legacy transition, and uninstall guidance;
- Redis/Valkey backend choice, OS-aware fresh-install selection, existing-Redis preservation, and migration readiness;
- memory sizing, presets, eviction settings, and PHP runtime setup;
- cPanel user functions and WHM administrative functions;
- CloudLinux Select PHP Version and CageFS guidance;
- roadmap, release history, and changelog;
- application connection examples for WordPress, Laravel, Magento, PHP, Node.js, and Python.

This project records the subject matter but does not copy vendor install or uninstall shell commands. ORM operators should use the repository's reviewed [installation](../installation.md) and [update lifecycle](../guides/update-lifecycle.md) documentation.

## cPanel functions described by the source

The cPanel section describes service state and lifecycle, connection details, presets for WordPress/Laravel/Magento/session-cache/generic use, advanced settings, backup and restore, usage history, health information, diagnostics export, application detection, connection examples, and setup preflight. It also describes Simple, Developer, and Advanced exposure levels.

The source's application-detection and connection-helper claims are not proof that each integration works on a host. ORM's supported implementation and limits are recorded in the [feature catalog](../features/catalog.md) and [integration matrix](../integrations.md).

## WHM functions described by the source

The WHM section describes a fleet dashboard and account list; Redis/Valkey selection, diagnostics, and migration; account CLI and backups; maintenance and recovery tools; global defaults; report/warn/enforce provider policy; package limits and auto-provisioning; reseller quotas; branding; update visibility; and security/audit surfaces.

The page keeps abuse/resource detection report-only by default. Its report/warn/enforce modes belong to the separate provider policy for provisioning and package limits; the documentation does not describe automatic remediation of abuse findings. ORM therefore keeps security findings advisory and does not attach service actions to those findings.

Some claims are versioned or partial on the source site. ORM tracks each capability as implemented, partial, planned, or requiring host validation in the feature catalog. A reference-page description does not upgrade that status.

## Runtime, policy, and compatibility themes

The page separates the Redis-compatible service from the PHP runtime extension and calls out EasyApache, CloudLinux PHP selection, and CageFS. It describes application connection information as host, port, password, and database details, and presents the managed instance as account-scoped.

The page also describes backend diagnostics, provider package policy, reseller quotas, report-only security thresholds, application setup, and migration readiness. Exact runtime compatibility and behavior must be established from ORM's own tests and cPanel validation records, not inferred from this page.
