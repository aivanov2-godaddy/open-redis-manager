# Reference research notes

## Scope and source

The public marketing, documentation, and update pages of UnderHost's cPanel Redis Manager were reviewed with REA on 2026-11-16. The overview page was rechecked on 2026-11-20. All three public pages were rechecked on 2026-11-22; each still identifies the product as v2.6.11. The capture IDs and limits are recorded in the [REA evidence ledger](rea-evidence.md). Page-by-page summaries are indexed in [reference-site notes](reference-site/README.md).

- [Product overview and screenshots](https://cpanelredismanager.com/index.php)
- [Documentation](https://cpanelredismanager.com/documentation.php)
- [Upgrade guide](https://cpanelredismanager.com/upgrade.php)

All three pages identify the displayed product version as 2.6.11. The marketing page contains twelve unique cPanel/WHM product screenshots with accessible descriptions and covers the dashboard, monitoring, configuration, account management, CLI, backups, recovery, global configuration, security, package controls and branding. The docs page contains sections for installation, requirements, backend behavior, WHM administration, cPanel user functions, CloudLinux, roadmap, release history, and six application connection examples. The update page describes an in-WHM update path and post-update checks.

A direct documentation-page review on 2026-11-16 confirmed that Branding is described as product name, logo, support URL, accent colors, and cPanel propagation (documentation section); the v2.6.7 changelog further describes four-color theming with labelled controls, a live preview, and UnderHost/Redis/Valkey presets with contrast warnings. The source does not specify exact color-role names or preset values. ORM defines roles as action, link, panel background, and text, and uses original color palettes without packaging third-party logo artwork.

### REA evidence

| Page | Evidence ID | Capture and coverage |
|---|---|---|
| `index.php` | `ev_8783b4e408ccd7c8c4c9de502c71432f27e5f8bc14705f28f6a5e23b0df67bc3` | Controlled replay in provider-owned Chromium 157.0.8103.51; DOM, accessibility text (29,316 bytes), and viewport screenshot retained. Captured navigation, product sections, screenshot gallery metadata, page links, image references, and FAQ/roadmap areas. |
| `documentation.php` | `ev_5e75e710d1a3a5c9087ee772a0a5c8635e2501aa334a7cc210113b16d295b5c5` | Controlled replay in provider-owned Chromium 157.0.8103.51; DOM, accessibility text (62,216 bytes), and viewport screenshot retained. Covers installation through application examples and release history. |
| `upgrade.php` | `ev_bc5794ef2fed1fc3190a0f6afdc5899aca22f5f7d3a770ed4f3a41797b5d078a` | Controlled replay in provider-owned Chromium 157.0.8103.51; DOM, accessibility text (8,904 bytes), and viewport screenshot retained. The page loaded directly; the earlier browser-challenge observation was not reproduced. |
| Homepage gallery interaction | `ev_1b6b2847f2916fed2041cf98a54ba7ec6e52cd6b2f775e9355531dea699ef6e9` | Read-only controlled replay opened the cPanel dashboard screenshot, advanced to Instance monitoring, and closed the viewer. All steps completed with DOM, accessibility, and screenshot evidence. |
| `index.php` (2026-11-22 recheck) | `ev_1e6930ee95f563411b0e5e01f90a7eb9e9d4401ca6144430d14cce46b420e2ae` | Complete capture in provider-owned Chromium 158.0.4370.33; DOM, accessibility (29,316 bytes), and viewport screenshot retained. The displayed version remains v2.6.11. |
| `documentation.php` (2026-11-22 recheck) | `ev_609d758796f6800cd7dbb3f16cbe068b3e594a4e9499a91e95fb866dcfd53ac0` | Complete capture in provider-owned Chromium 158.0.4370.33; DOM, accessibility (62,216 bytes), and viewport screenshot retained. The displayed version remains v2.6.11. |
| `upgrade.php` (2026-11-22 recheck) | `ev_1ff2bca3b4e60ff819d73ac299e9bdd40b80bd7b7804f7c392b6c4908c22d9b9` | Complete capture in provider-owned Chromium 158.0.4370.33; DOM, accessibility (8,904 bytes), and viewport screenshot retained. The displayed version remains v2.6.11. |

REA reported complete capture within the requested page views. These are observations of public web pages in a controlled browser replay, not shipped-artifact evidence. They do not establish that the described plugin behavior exists in a particular binary, that all controls work, or that the public copy is technically accurate. The capture does not include the vendor's licensed package, authenticated WHM/cPanel runtime, backend services, or server-side source. Browser process identity beyond the selected executable and host platform/architecture were unavailable. See [the REA evidence ledger](rea-evidence.md) for the research boundary and coverage ledger.

## Observed feature groups

- **Account UI:** instance lifecycle, connection secret reveal, presets and advanced configuration, monitoring history, health/preflight, backups/restore, app detection and framework snippets, masked diagnostics.
- **WHM:** dashboard and account table, authenticated Redis CLI, fleet backups, scan-first recovery, backend detection/selection, global defaults, report/warn/enforce policy, exposure modes, packages, reseller quotas, branding, update checks and audit.
- **Backend lifecycle:** Redis and Valkey support, OS-aware fresh-install selection, preservation of existing Redis on upgrade, explicit per-account migration with snapshot/verification/rollback.
- **Application integrations:** WordPress, LiteSpeed Cache, Laravel, Magento, PHP, Node.js and Python; CloudLinux PHP Selector, CageFS and EasyApache runtime guidance.
- **Roadmap themes on source site:** observability/slow logs, workers/auto-healing, cross-server transfer, API/webhooks, cluster/Sentinel and DirectAdmin.

## Evidence limits

This review used public page DOM, accessible metadata, image descriptions, viewport screenshots, and a read-only gallery interaction. The vendor's authenticated cPanel/WHM application was not available for interaction; therefore hidden workflows, API contracts, exact runtime behavior, and error handling are not established. The reference pages were captured without activating purchase, download, install, update, or account actions. The feature catalog marks current repository behavior as prototype or planned accordingly.

## Redis/Valkey authentication counter

The Redis [`INFO` reference](https://redis.io/docs/latest/commands/info/) documents `acl_access_denied_auth` as the number of authentication failures and marks it as added in Redis 8.0. Valkey's [`INFO` reference](https://valkey.io/commands/info/) also lists the field and warns that fields vary by version. ORM detects the field at runtime; missing fields are unknown, not zero. The aggregate counter contains no client identity and does not establish malicious intent. The implementation reports only bounded monotonic deltas and retains reset/gap states as unknown.

## Attribution and originality

This project uses the product site as a functional reference. The feature descriptions here are summarized in original wording. Vendor prose, logos, screenshots, source code and trademarks are not copied into this repository. Open Redis Manager's interface and icon set are original. Redis, Valkey and cPanel remain the property of their respective owners; this project is not affiliated with or endorsed by those projects or cPanel, L.L.C.
