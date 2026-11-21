<h1 align="center">Open Redis Manager (ORM)</h1>

<p align="center"><img src="assets/orm-mark.svg" width="180" alt="Open Redis Manager red tile logo with a white cache cube"></p>

An open-source Redis and Valkey control panel for cPanel and WHM. ORM manages direct Redis/Valkey instances and can discover and control the lifecycle of existing cPanel EA Podman Redis/Valkey containers owned by the current account. WHM includes root-only fleet operations, bounded snapshot batches, scan-guided service and safe configuration recovery, audit history, and guarded Redis-to-Valkey migration. Production readiness still requires the complete supported-host validation matrix.

> **Status:** early development. The standalone demo screens use sample data. The authenticated cPanel page and WHM backend selector use a closed broker for ORM-managed direct instances. The cPanel page also detects current-account cPanel EA Podman Redis/Valkey sockets and generates connection settings without taking over their lifecycle. Root WHM provides on-demand fleet aggregates and create/restore batches capped at two visible accounts. Validate against a disposable cPanel host before production use.

## What is here

- A responsive cPanel and WHM interface prototype in [`index.php`](index.php).
- cPanel and WHM entry points, a root-owned backend choice, and account-scoped direct Redis/Valkey provision/status/configure/start/stop through a Linux peer-identity broker. The account page discovers the current account's EA Podman Redis/Valkey containers and offers start/stop/restart through cPanel's fixed account-level tool. The authenticated Podman web lifecycle passed a single-account Redis smoke on one disposable host; Valkey web actions and the broader host matrix remain unverified. WHM diagnostics and fleet metrics use fixed, validated reads.
- A read-only Redis/Valkey backend discovery command in [`bin/orm`](bin/orm).
- A feature-by-feature product inventory and original docs in [`docs/`](docs/).
- Current implementation maturity, cPanel vendor host eligibility, ORM validation coverage, and a secret-free disposable-host record template are documented in [`docs/release-notes.md`](docs/release-notes.md) and the [host validation matrix](docs/validation/compatibility-matrix.md).
- The custom ORM cache mark is available as [`assets/orm-mark.svg`](assets/orm-mark.svg), included in the cPanel and WHM integrations, and shown in the [logo preview](screenshots/orm-logo.png).
- Root WHM can set future-instance memory, eviction, database, snapshot-retention and metrics-history defaults; manage package and reseller ceilings; choose report-only/warn/enforce behavior; and set Simple/Developer/Advanced cPanel exposure. New instances record the defaults that affect their configuration and retention. Existing instances are not rewritten when defaults change.
- Root WHM can migrate one running ORM-managed Redis 6.2–7.2 account to Valkey 7.2+, after acknowledging that application writers are paused. ORM snapshots, validates and attempts rollback; [migration limits and recovery](docs/guides/redis-valkey-migration.md) explain the remaining live validation gate.
- Root WHM can generate a one-minute-rate-limited, report-only security review from current fleet memory/client/hit-ratio snapshots and normalized AUTH management events. Eviction/operation-rate data, Redis login attempts, and password-strength checks remain explicitly unavailable.
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

The installed cPanel and WHM entry points expose a first lifecycle slice. WHM must choose an installed default backend; a cPanel user can initialize, view status, start and stop their own service, and use the controls shown by the provider's exposure tier. Simple shows basic setup, lifecycle, endpoint, and PhpRedis guidance. Developer adds workload presets, live and historical metrics, bounded configuration, application helpers, and diagnostics.

Advanced adds explicit RDB backup and restore; restore validates the snapshot, creates a safety copy, briefly stops the service, replaces only `dump.rdb`, restarts it, and rolls back if startup fails. Optional Redis AUTH is off by default; an account owner can enable, disable, or rotate it for a running instance, then update application settings manually. A generated password is shown once after successful verification. Provider exposure changes visibility and does not grant permissions. Package rules can restrict new provisioning, memory ceilings, and snapshot retention. Reseller quotas cap configured instances and aggregate configured memory; stopped instances count and existing instances remain grandfathered.

Policy defaults to report-only, where violations are logged, while warn adds a fixed cPanel notice and enforce blocks configured violations. Existing instances can change memory (8–64 MiB), an allowlisted eviction policy, client limit (10–100), and idle timeout (0–300 seconds). Reducing memory can evict cached keys immediately. Direct Redis commands through the account's own socket can change runtime values independently of broker-saved config. The cPanel page shows the account-private Unix socket path and copyable PhpRedis, WordPress/WooCommerce, LiteSpeed Cache, Laravel, Magento/Adobe Commerce, node-redis, and redis-py connection helpers when exposure allows. These examples do not edit application files or enable application features.

Latest metrics and hourly history use the retention value recorded for each new instance (7–90 days), with root-owned history capped at 2,160 samples and 1 MiB. Legacy instances retain their 30-day history behavior. Authenticated users can preview and download a minimal diagnostics JSON report without account names, paths, passwords, keys, values, payloads, sessions, logs, or command output. Instances run under the cPanel account with TCP disabled and persistence off by default. Root WHM also exposes per-account snapshot creation and restore with account-specific results, a root-only on-demand fleet summary, and capped two-account snapshot batches with per-account outcomes. Larger all-fleet operations and broader disposable-host validation remain open.

The installed cPanel and WHM entry points expose direct and Podman connection modes. ORM-managed direct instances support account-scoped lifecycle, configuration, metrics, snapshots, and Redis-to-Valkey migration. Existing cPanel EA Podman containers are discovered only for the current account, optionally PINGed through PhpRedis, and shown with socket-based examples; ORM offers only fixed start/stop/restart controls while cPanel retains package configuration and data ownership. Provider controls, rollback behavior, and production limits are described in the [feature catalog](docs/features/catalog.md) and [cPanel Redis/Valkey container guide](docs/guides/cpanel-podman.md).

See the [preset guide](docs/guides/configuration-presets.md), [instance lifecycle guide](docs/guides/instance-lifecycle.md), [monitoring and diagnostics guide](docs/guides/monitoring-diagnostics.md), [provider policy guide](docs/guides/provider-package-policy.md), and [operations guide](docs/operations.md) for current limits and validation status.

## Documentation

- [Product overview](docs/overview.md)
- [Feature catalog](docs/features/catalog.md)
- [Integration matrix](docs/integrations.md)
- [Installation and compatibility plan](docs/installation.md)
- [Live cPanel smoke test](docs/validation/cpanel-smoke.md)
- [Instance lifecycle](docs/guides/instance-lifecycle.md)
- [cPanel Redis and Valkey containers](docs/guides/cpanel-podman.md)
- [Security model](docs/security-model.md)
- [Provider policy and reseller quotas](docs/guides/provider-package-policy.md)
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

Production integration still requires a supported host matrix and end-to-end validation on disposable cPanel systems. The repository has a reviewed privileged service layer, cPanel/WHM entry points, package discovery, and a root-only signed updater; the updater accepts only manually staged, locally signed releases for an exact v3 install manifest. See the docs and roadmap before treating any screen as production-ready.

## License

MIT. See [LICENSE](LICENSE).
