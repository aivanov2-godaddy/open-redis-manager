<h1 align="center">Open Redis Manager (ORM)</h1>

<p align="center"><img src="assets/orm-mark.svg" width="180" alt="Open Redis Manager connected cache core logo"></p>

An open-source Redis and Valkey control panel for cPanel and WHM. This repository includes a standalone PHP prototype and an early installed integration with account-scoped Redis/Valkey lifecycle controls, hourly usage history, account-level backups and restore, read-only connection guidance, WHM backend discovery, and root-only per-account service and snapshot controls. Production readiness still requires disposable-host validation.

> **Status:** early development. The standalone demo screens use sample data. The authenticated cPanel page and WHM backend selector are wired to a closed broker for initialization, status, live and hourly metrics, bounded configuration, lifecycle controls, and account backups with restore. Root WHM can also create and restore snapshots for a selected account. The manual installer and lifecycle still need a supported disposable-host validation matrix. Do not install on a production server.

## What is here

- A responsive cPanel and WHM interface prototype in [`index.php`](index.php).
- cPanel and WHM entry points, a root-owned backend choice, and account-scoped Redis/Valkey provision/status/configure/start/stop through a Linux peer-identity broker; lifecycle validation is still required on a disposable cPanel host.
- A read-only Redis/Valkey backend discovery command in [`bin/orm`](bin/orm).
- A feature-by-feature product inventory and original docs in [`docs/`](docs/).
- The ORM red orbital cache mark is available as [`assets/orm-mark.svg`](assets/orm-mark.svg), included in the cPanel and WHM integrations, and shown in the [logo preview](screenshots/orm-logo.png).
- Root WHM can manage package-specific provisioning, memory, and snapshot-retention policies in report-only or enforce mode; reseller quotas and exposure levels remain planned.
- Original screenshots of the prototype in [`screenshots/`](screenshots/).
- An implementation roadmap and GitHub issue drafts in [`project/`](project/).

## Preview

Run the demo locally with PHP 8.1 or newer:

```sh
php -S 127.0.0.1:8080
```

Open `http://127.0.0.1:8080/`. Use **cPanel** and **WHM** in the header to switch between the account and administrator surfaces. Every visible menu item opens a documented prototype screen.

## Product scope

The planned product covers isolated per-account instances; Redis and Valkey backend discovery; cPanel lifecycle, metrics, configuration, presets, backups, application helpers and diagnostics; and WHM fleet operations, recovery, package and reseller policy, security, branding, audit, and updates. The observed feature inventory and delivery boundaries are in [`docs/features/catalog.md`](docs/features/catalog.md).

## Functional slices

The repository includes a read-only CLI discovery command for common Redis and Valkey server/client binaries and systemd unit states:

```sh
php bin/orm backend:discover --json
```

This command does not mutate the host and is not exposed through the unauthenticated prototype UI. Platform and package coverage limits are documented in [`docs/guides/backend-discovery.md`](docs/guides/backend-discovery.md).

The installed cPanel and WHM entry points expose a first lifecycle slice. WHM must choose an installed default backend; a cPanel user can initialize, view status, read live or stale metrics, configure bounded settings, start and stop their own service, and create, list, download, and restore explicit RDB snapshots for that account. Restore validates the selected RDB, creates and retains a safety snapshot, briefly stops the service, replaces only `dump.rdb`, restarts it, and rolls back from the safety snapshot if startup fails. The cPanel interface confirms the interruption and possible loss of writes newer than the snapshot. ORM keeps the latest three snapshots and does not turn on Redis persistence or scheduled backups. During initialization, the user can choose a fixed WordPress, Laravel, Magento, Session Cache, or Generic preset; the broker sets its memory limit and keeps every profile within the 64 MiB cap. Existing instances can change memory (8–64 MiB), an allowlisted eviction policy, client limit (10–100), and idle timeout (0–300 seconds). Reducing memory can evict keys immediately. Package and reseller ceilings are not available, and direct Redis commands through the account's own socket can change runtime values independently of the broker-saved config. The cPanel page shows the account-private Unix socket path and copyable PhpRedis, WordPress/WooCommerce, LiteSpeed Cache, Laravel, Magento/Adobe Commerce, node-redis, and redis-py connection helpers. These examples do not edit application files or enable application features. Latest metrics and hourly history are retained for up to 30 days. Authenticated users can preview and download a minimal diagnostics JSON report without account names, paths, credentials, keys, values, payloads, sessions, logs, or command output. Instances run under the cPanel account with TCP disabled and persistence off by default. Root WHM also exposes per-account snapshot creation and restore with account-specific results; all-fleet batch operations and disposable-host validation remain open. See the [preset guide](docs/guides/configuration-presets.md), [instance lifecycle guide](docs/guides/instance-lifecycle.md), [monitoring and diagnostics guide](docs/guides/monitoring-diagnostics.md), and [operations guide](docs/operations.md) for current limits and validation status.

## Documentation

- [Product overview](docs/overview.md)
- [Feature catalog](docs/features/catalog.md)
- [Integration matrix](docs/integrations.md)
- [Installation and compatibility plan](docs/installation.md)
- [Live cPanel smoke test](docs/validation/cpanel-smoke.md)
- [Instance lifecycle](docs/guides/instance-lifecycle.md)
- [Security model](docs/security-model.md)
- [Provider package policy](docs/guides/provider-package-policy.md)
- [Operations: monitoring, backups, recovery](docs/operations.md)
- [Reference site content map](docs/features/website-content-map.md)
- [FAQ reference summary](docs/faq-reference.md)
- [Release and roadmap reference](docs/roadmap-reference.md)
- [Prototype screenshot index](screenshots/README.md)
- [Reference notes and attribution](docs/source-notes.md)
- [Milestones and issue drafts](project/README.md)

## Design principles

1. Preserve existing Redis instances unless an administrator explicitly migrates them.
2. Keep cPanel users inside their own account boundary; keep root operations in WHM.
3. Start provider policies in report-only mode and make enforcement an explicit opt-in.
4. Mask credentials by default, avoid secrets in logs and exports, and require CSRF protection for changes.
5. Make destructive or service-impacting actions explain their effect and offer a recovery path.

## Development boundary

Production integration requires a reviewed privileged service layer, cPanel UAPI/WHM ACL integration, supported-OS/package discovery, upgrade support, and end-to-end validation on disposable cPanel systems. See the docs and roadmap before treating any screen as an implemented feature.

## License

MIT. See [LICENSE](LICENSE).
