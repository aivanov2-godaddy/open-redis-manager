# REA evidence and coverage ledger

This ledger records what was inspected from the public cPanel Redis Manager reference and what remains unverified. It supports the feature catalog; it is not a claim that ORM reproduces a proprietary binary.

## Inspection method

REA used a provider-owned Chromium process for controlled browser replays of the public overview, documentation, and update pages. The pages were allowed to settle before DOM and accessibility evidence were retained. The upgrade page also retained a viewport screenshot. Public pages were treated as untrusted reference data: no vendor installer, download, purchase action, or privileged WHM/cPanel action was run.

## Public page coverage

| Reference area | What was observed | ORM documentation |
|---|---|---|
| Marketing home | Product audience and claims, Redis/Valkey positioning, cache request flow, application examples, cPanel/WHM value proposition, release/pricing/FAQ themes, navigation and product CTAs. | [Website content map](features/website-content-map.md), [FAQ summary](faq-reference.md), [roadmap summary](roadmap-reference.md) |
| Screenshot gallery | Three cPanel images and nine WHM images, with accessible names and captions covering dashboard, monitoring, configuration/backups, accounts, CLI, recovery, defaults, security, packages, and branding. The site uses an accessible lightbox with previous/next/close controls. | [Screenshot map](features/screenshot-map.md) |
| Documentation | Installation and removal, Redis/Valkey backend handling, CloudLinux/PHP runtime layers, WHM and cPanel functions, presets and tuning, roadmap, release chronology, licensing notes, and WordPress/Laravel/Magento/PHP/Node.js/Python examples. | [Feature catalog](features/catalog.md), [operator guides](README.md#operator-guides), [integrations](integrations.md) |
| Update page | WHM in-panel update workflow, stated preservation of instances/account configuration, version verification checklist, current public version 2.6.11, and planned 2.7.x observability/debugging themes. | [Source notes](source-notes.md), [feature catalog](features/catalog.md) |

The gallery's screenshot images and vendor brand assets are referenced only as evidence; they are not redistributed in this repository. ORM uses its own interface and icon assets. The reference site's icon presentation is chiefly a repeated Redis icon in feature badges plus Redis/Valkey logos; it is not treated as a reusable icon library.

## Evidence records

The complete REA records are retained in the active REA evidence session. Identifiers are included here so the observations can be revisited without relying on prose summaries.

| Page | Evidence ID | Authority | Confidence | Capture status |
|---|---|---|---|---|
| `https://cpanelredismanager.com/index.php` | `ev_5e7f3c60a37bf334678aa45e56c1a212ffb90475a1cb0dce40fca9afede04fc9` | Controlled replay | Observed | Complete within requested capture; DOM 69,194 bytes. |
| `https://cpanelredismanager.com/documentation.php` | `ev_65f8daa1b9ac19952eaaa9b19a65782c09a3006f0075e76c03f45d801b05be26` | Controlled replay | Observed | Complete within requested capture; DOM 99,160 bytes. |
| `https://cpanelredismanager.com/upgrade.php` | `ev_0aa38dc7ef4b0513c1e2f77cb2f73832cf731a7a5436c2889e8b5b3361d6b075` | Controlled replay | Observed | Complete within requested capture; DOM and viewport screenshot retained. |

## What this does not establish

- The feature descriptions are claims made by the public website, not independently verified implementation facts.
- No authenticated cPanel/WHM screens, installed package, server-side source, API, license service, or billing integration was inspected.
- Page content does not reveal every branch, permission check, failure state, race condition, or error message in the actual plugin.
- The overview gallery documents twelve screenshots (the first cPanel dashboard is reused in a hero and the gallery); the repository's four screenshots are original ORM prototype captures, not screenshots of the vendor product.
- REA's controlled replay records the rendered browser view and its limitations; it is not a packet-level recording or proof of the page's underlying server implementation.

For those reasons, the PHP UI in this repository remains a safe, data-backed prototype. Features that could change Redis processes, files, credentials, accounts, packages, or server policy require an implementation review against the actual cPanel/WHM APIs and security model before being enabled.
