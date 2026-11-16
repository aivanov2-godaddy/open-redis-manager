<h1 align="center">Open Redis Manager (ORM)</h1>

<p align="center"><img src="assets/orm-mark.svg" width="180" alt="Open Redis Manager red tile logo with a white cache cube"></p>

An open-source Redis and Valkey control panel for cPanel and WHM. ORM manages direct Redis/Valkey instances and can discover an existing cPanel EA Podman Redis/Valkey cache for account-scoped health and application connection guidance. WHM includes root-only fleet operations, bounded snapshot batches, audit history, and guarded Redis-to-Valkey migration. Production readiness still requires the complete supported-host validation matrix.

> **Status:** early development. The standalone demo screens use sample data. The authenticated cPanel page and WHM backend selector use a closed broker for ORM-managed direct instances. The cPanel page also detects current-account cPanel EA Podman Redis/Valkey sockets and generates connection settings without taking over their lifecycle. Root WHM provides on-demand fleet aggregates and create/restore batches capped at two visible accounts. Validate against a disposable cPanel host before production use.

## What is here

- A responsive cPanel and WHM interface prototype in [`index.php`](index.php).
- cPanel and WHM entry points, a root-owned backend choice, and account-scoped direct Redis/Valkey provision/status/configure/start/stop through a Linux peer-identity broker. The account page detects cPanel EA Podman Redis/Valkey sockets without mutating their containers. WHM diagnostics and fleet metrics use fixed, validated reads. Lifecycle validation remains in progress on the disposable cPanel host.
- A read-only Redis/Valkey backend discovery command in [`bin/orm`](bin/orm).
- A feature-by-feature product inventory and original docs in [`docs/`](docs/).
- Current implementation maturity, cPanel vendor host eligibility, ORM validation coverage, and a secret-free disposable-host record template are documented in [`docs/release-notes.md`](docs/release-notes.md) and the [host validation matrix](docs/validation/compatibility-matrix.md).
- The custom ORM cache mark is available as [`assets/orm-mark.svg`](assets/orm-mark.svg), included in the cPanel and WHM integrations, and shown in the [logo preview](screenshots/orm-logo.png).
- Root WHM can manage package and reseller provisioning/memory ceilings, choose report-only/warn/enforce behavior, and set Simple/Developer/Advanced cPanel exposure. Existing instances are grandfathered when policy changes.
- Root WHM can migrate one running ORM-managed Redis 6.2–7.2 account to Valkey 7.2+, after acknowledging that application writers are paused. ORM snapshots, validates and attempts rollback; [migration limits and recovery](docs/guides/redis-valkey-migration.md) explain the remaining live validation gate.
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

The installed cPanel and WHM entry points expose direct and Podman connection modes. ORM-managed direct instances support account-scoped lifecycle, configuration, metrics, snapshots, and Redis-to-Valkey migration. Existing cPanel EA Podman caches are discovered only for the current account, optionally PINGed through PhpRedis, and shown with socket-based examples; cPanel remains responsible for their lifecycle and data. Root WHM provides a root-only, on-demand fleet summary and capped two-account snapshot batches with per-account outcomes. Provider controls, rollback behavior, and production limits are described in the [feature catalog](docs/features/catalog.md) and [cPanel Redis/Valkey container guide](docs/guides/cpanel-podman.md).

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

Production integration requires a reviewed privileged service layer, cPanel UAPI/WHM ACL integration, supported-OS/package discovery, upgrade support, and end-to-end validation on disposable cPanel systems. See the docs and roadmap before treating any screen as an implemented feature.

## License

MIT. See [LICENSE](LICENSE).
