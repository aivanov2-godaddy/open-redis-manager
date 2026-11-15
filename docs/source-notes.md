# Reference research notes

## Scope and source

The public marketing and documentation pages of UnderHost's cPanel Redis Manager were reviewed on 2026-11-15:

- [Product overview and screenshots](https://cpanelredismanager.com/index.php)
- [Documentation](https://cpanelredismanager.com/documentation.php)
- [Upgrade guide](https://cpanelredismanager.com/upgrade.php) (a browser challenge prevented access during this review)

The pages identify the displayed product version as 2.6.11. The marketing page lists nine cPanel/WHM product screenshots by accessible text and describes the dashboard, monitoring, configuration, account management, CLI, backups, recovery, global configuration, security, package controls and branding. The docs page contains sections for installation, requirements, backend behavior, WHM administration, cPanel user functions, CloudLinux, roadmap and release history.

## Observed feature groups

- **Account UI:** instance lifecycle, connection secret reveal, presets and advanced configuration, monitoring history, health/preflight, backups/restore, app detection and framework snippets, masked diagnostics.
- **WHM:** dashboard and account table, authenticated Redis CLI, fleet backups, scan-first recovery, backend detection/selection, global defaults, report/warn/enforce policy, exposure modes, packages, reseller quotas, branding, update checks and audit.
- **Backend lifecycle:** Redis and Valkey support, OS-aware fresh-install selection, preservation of existing Redis on upgrade, explicit per-account migration with snapshot/verification/rollback.
- **Application integrations:** WordPress, LiteSpeed Cache, Laravel, Magento, PHP, Node.js and Python; CloudLinux PHP Selector, CageFS and EasyApache runtime guidance.
- **Roadmap themes on source site:** observability/slow logs, workers/auto-healing, cross-server transfer, API/webhooks, cluster/Sentinel and DirectAdmin.

## Evidence limits

This review used the public site text and image descriptions. The vendor's live cPanel/WHM application was not available for interaction; therefore its hidden workflows, API contracts, exact layout behavior and error handling are not established. The upgrade page was blocked by a browser challenge. REA's passive browser inspection could not attach because no Chrome DevTools endpoint was exposed in this environment. The feature catalog marks current repository behavior as prototype or planned accordingly.

## Attribution and originality

This project uses the product site as a functional reference. The feature descriptions here are summarized in original wording. Vendor prose, logos, screenshots, source code and trademarks are not copied into this repository. Open Redis Manager's interface and icon set are original. Redis, Valkey and cPanel remain the property of their respective owners; this project is not affiliated with or endorsed by those projects or cPanel, L.L.C.
