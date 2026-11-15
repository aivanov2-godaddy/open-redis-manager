# Reference research notes

## Scope and source

The public marketing, documentation, and update pages of UnderHost's cPanel Redis Manager were reviewed with REA on 2026-11-15:

- [Product overview and screenshots](https://cpanelredismanager.com/index.php)
- [Documentation](https://cpanelredismanager.com/documentation.php)
- [Upgrade guide](https://cpanelredismanager.com/upgrade.php)

All three pages identify the displayed product version as 2.6.11. The marketing page contains twelve unique cPanel/WHM product screenshots with accessible descriptions and covers the dashboard, monitoring, configuration, account management, CLI, backups, recovery, global configuration, security, package controls and branding. The docs page contains sections for installation, requirements, backend behavior, WHM administration, cPanel user functions, CloudLinux, roadmap, release history, and six application connection examples. The update page describes an in-WHM update path and post-update checks.

### REA evidence

| Page | Evidence ID | Capture and coverage |
|---|---|---|
| `index.php` | `ev_5e7f3c60a37bf334678aa45e56c1a212ffb90475a1cb0dce40fca9afede04fc9` | Controlled replay in provider-owned Chromium; full 69,194-byte DOM retained. Captured navigation, product sections, screenshot gallery metadata, page links, image references, and FAQ/roadmap areas. |
| `documentation.php` | `ev_65f8daa1b9ac19952eaaa9b19a65782c09a3006f0075e76c03f45d801b05be26` | Controlled replay in provider-owned Chromium; full 99,160-byte DOM retained. Covers installation through application examples and release history. |
| `upgrade.php` | `ev_0aa38dc7ef4b0513c1e2f77cb2f73832cf731a7a5436c2889e8b5b3361d6b075` | Controlled replay in provider-owned Chromium; DOM, accessibility, history, URL, and viewport screenshot requested and captured. The page loaded directly; the earlier browser-challenge observation was not reproduced. |

REA reported complete capture within the requested page views. These are observations of public web pages in a controlled browser replay, not shipped-artifact evidence. They do not establish that the described plugin behavior exists in a particular binary, that all controls work, or that the public copy is technically accurate. The capture does not include the vendor's licensed package, authenticated WHM/cPanel runtime, backend services, or server-side source. Browser process identity beyond the selected executable and host platform/architecture were unavailable. See [the REA evidence ledger](rea-evidence.md) for the research boundary and coverage ledger.

## Observed feature groups

- **Account UI:** instance lifecycle, connection secret reveal, presets and advanced configuration, monitoring history, health/preflight, backups/restore, app detection and framework snippets, masked diagnostics.
- **WHM:** dashboard and account table, authenticated Redis CLI, fleet backups, scan-first recovery, backend detection/selection, global defaults, report/warn/enforce policy, exposure modes, packages, reseller quotas, branding, update checks and audit.
- **Backend lifecycle:** Redis and Valkey support, OS-aware fresh-install selection, preservation of existing Redis on upgrade, explicit per-account migration with snapshot/verification/rollback.
- **Application integrations:** WordPress, LiteSpeed Cache, Laravel, Magento, PHP, Node.js and Python; CloudLinux PHP Selector, CageFS and EasyApache runtime guidance.
- **Roadmap themes on source site:** observability/slow logs, workers/auto-healing, cross-server transfer, API/webhooks, cluster/Sentinel and DirectAdmin.

## Evidence limits

This review used public page DOM, accessible metadata, image descriptions, and one update-page viewport screenshot. The vendor's authenticated cPanel/WHM application was not available for interaction; therefore hidden workflows, API contracts, exact runtime behavior, and error handling are not established. The reference pages were captured without activating purchase, download, install, update, or account actions. The feature catalog marks current repository behavior as prototype or planned accordingly.

## Attribution and originality

This project uses the product site as a functional reference. The feature descriptions here are summarized in original wording. Vendor prose, logos, screenshots, source code and trademarks are not copied into this repository. Open Redis Manager's interface and icon set are original. Redis, Valkey and cPanel remain the property of their respective owners; this project is not affiliated with or endorsed by those projects or cPanel, L.L.C.
