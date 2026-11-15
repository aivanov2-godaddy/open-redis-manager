# Open Redis Manager (ORM)

An open-source Redis and Valkey control panel for cPanel and WHM. This repository starts with a standalone, dependency-free PHP prototype and a documented implementation plan for a production cPanel integration.

> **Status:** early development. The demo screens use sample data. The cPanel/WHM scaffolds and installer have not been validated on a cPanel host. A root-run identity-only broker is under development; it does not operate Redis or Valkey. Do not install on a production server.

## What is here

- A responsive cPanel and WHM interface prototype in [`index.php`](index.php).
- cPanel and WHM entry points, a cPanel session identity check with a root-run Linux peer-identity broker, and a development-only installer in [`packaging/`](packaging/README.md); the lifecycle has not been validated on a cPanel host.
- A read-only Redis/Valkey backend discovery command in [`bin/orm`](bin/orm).
- A feature-by-feature product inventory and original docs in [`docs/`](docs/).
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

## First functional slice

The repository includes a read-only CLI discovery command for common Redis and Valkey server/client binaries and systemd unit states:

```sh
php bin/orm backend:discover --json
```

This command does not mutate the host and is not exposed through the unauthenticated prototype UI. Platform and package coverage limits are documented in [`docs/guides/backend-discovery.md`](docs/guides/backend-discovery.md).

## Documentation

- [Product overview](docs/overview.md)
- [Feature catalog](docs/features/catalog.md)
- [Integration matrix](docs/integrations.md)
- [Installation and compatibility plan](docs/installation.md)
- [Live cPanel smoke test](docs/validation/cpanel-smoke.md)
- [Security model](docs/security-model.md)
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
