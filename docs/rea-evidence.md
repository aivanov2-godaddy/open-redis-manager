# REA evidence and coverage ledger

This ledger records what was inspected from the public cPanel Redis Manager reference and what remains unverified. It supports the feature catalog; it is not a claim that ORM reproduces a proprietary binary.

## Inspection method

REA used provider-owned Chromium 157.0.8103.51 processes for controlled replays of the public overview, documentation, and update pages. Each page was allowed to settle before DOM, accessibility, and viewport screenshot evidence were retained; each capture completed and its owned browser process was terminated. A separate read-only gallery replay opened the cPanel dashboard screenshot, advanced to Instance monitoring, and closed the viewer. All four steps completed with DOM, accessibility, and screenshot evidence. Public page content remains untrusted reference data: no vendor installer, download, purchase action, or privileged WHM/cPanel action was run.

## Public page coverage

| Reference area | What was observed | ORM documentation |
|---|---|---|
| Marketing home | Product audience and claims, Redis/Valkey positioning, cache request flow, application examples, cPanel/WHM value proposition, release/pricing/FAQ themes, navigation and product CTAs. | [Website content map](features/website-content-map.md), [FAQ summary](faq-reference.md), [roadmap summary](roadmap-reference.md) |
| Screenshot gallery | Three cPanel images and nine WHM images, with accessible names and captions covering dashboard, monitoring, configuration/backups, accounts, CLI, recovery, defaults, security, packages, and branding. A controlled replay opened the cPanel dashboard, advanced to Instance monitoring, and closed the accessible lightbox using its Previous screenshot, Next screenshot, and Close screenshot viewer controls. | [Screenshot map](features/screenshot-map.md) |
| Documentation | Installation and removal, Redis/Valkey backend handling, CloudLinux/PHP runtime layers, WHM and cPanel functions, presets and tuning, roadmap, release chronology, licensing notes, and WordPress/Laravel/Magento/PHP/Node.js/Python examples. | [Feature catalog](features/catalog.md), [operator guides](README.md#operator-guides), [integrations](integrations.md) |
| Update page | WHM in-panel update workflow, stated preservation of instances/account configuration, version verification checklist, current public version 2.6.11, and planned 2.7.x observability/debugging themes. | [Source notes](source-notes.md), [feature catalog](features/catalog.md) |

A direct read of the current public documentation on 2026-11-16 also confirmed the v2.6.7 branding claims: four labelled theme colors, live preview, and UnderHost/Redis/Valkey color presets with contrast warnings. The reference does not specify the color roles or exact preset values; ORM's four roles and color values are original design choices recorded in [source notes](source-notes.md).

### Read-only recheck on 2026-11-17

REA reopened the public home, documentation, and upgrade pages in provider-owned Chromium 157.0.8103.51 and captured their DOM/accessibility state after a short settle. The pages still identify the reference product as v2.6.11. The homepage replay also retained selected response bodies; no write flow or authenticated product surface was exercised in this recheck. The new records confirm the page inventory and feature claims below; earlier records above remain the screenshot captures used by the gallery review.

The gallery's screenshot images and vendor brand assets are referenced only as evidence; they are not redistributed in this repository. ORM uses its own interface and icon assets. The reference site's icon presentation is chiefly a repeated Redis icon in feature badges plus Redis/Valkey logos; it is not treated as a reusable icon library.

### Read-only homepage recheck on 2026-11-20

REA opened only the public overview page in provider-owned Chromium 158.0.8127.36 and captured the settled DOM, accessibility tree, URL, and viewport screenshot. The page still identifies the reference product as v2.6.11. The capture was complete within the selected page; it does not establish behavior in the vendor's authenticated cPanel/WHM product. No purchase, download, install, update, or account action was performed.

### Read-only page recheck on 2026-11-21

REA launched provider-owned Chromium 158.0.8127.36 to the public home, documentation, and upgrade pages, waited 1.2–1.5 seconds, and captured DOM/accessibility data plus page-scoped network metadata. All three scenarios completed; each page still displayed v2.6.11. The home capture also retained its final viewport screenshot. The documentation and upgrade rechecks did not request screenshots. No response bodies, credentials, authenticated product screens, purchase, download, install, update, or account actions were captured or performed. See the separate [Home](reference-site/home.md), [Documentation](reference-site/documentation.md), [Upgrade](reference-site/upgrade.md), [Screenshot Gallery](reference-site/screenshots.md), and [Roadmap](reference-site/roadmap.md) summaries.

### Read-only page recheck on 2026-11-22

REA captured the public home, documentation, and upgrade pages in provider-owned Chromium 158.0.4370.33. All three captures completed with DOM, accessibility, and viewport screenshot evidence; the pages continued to display v2.6.11. Accessibility captures measured 29,316 bytes for the home, 62,216 bytes for documentation, and 8,904 bytes for the upgrade page. These are public reference observations only; no authenticated product screens, response bodies, or account actions were involved. The page inventory and feature summaries did not require changes.

## Evidence records

The complete REA records are retained in the active REA evidence session. Identifiers are included here so the observations can be revisited without relying on prose summaries.

| Page | Evidence ID | Authority | Confidence | Capture status |
|---|---|---|---|---|
| `https://cpanelredismanager.com/index.php` | `ev_8783b4e408ccd7c8c4c9de502c71432f27e5f8bc14705f28f6a5e23b0df67bc3` | Controlled replay | Derived from captured DOM/accessibility | Complete; homepage accessibility text 29,316 bytes; DOM, accessibility, and screenshot captured. |
| `https://cpanelredismanager.com/index.php` (2026-11-20 recheck) | `ev_7a60480d4a071a30d2a1abcf8748237715de94137ac91eb25a04f169cac0bb97` | Controlled replay | Derived from captured DOM/accessibility | Complete; Chromium 158.0.8127.36; accessibility text 29,316 bytes; DOM, accessibility, URL, and screenshot captured; page reports v2.6.11. |
| `https://cpanelredismanager.com/documentation.php` | `ev_5e75e710d1a3a5c9087ee772a0a5c8635e2501aa334a7cc210113b16d295b5c5` | Controlled replay | Derived from captured DOM/accessibility | Complete; documentation accessibility text 62,216 bytes; DOM, accessibility, and screenshot captured. |
| `https://cpanelredismanager.com/upgrade.php` | `ev_bc5794ef2fed1fc3190a0f6afdc5899aca22f5f7d3a770ed4f3a41797b5d078a` | Controlled replay | Derived from captured DOM/accessibility | Complete; update-page accessibility text 8,904 bytes; DOM, accessibility, and screenshot captured. |
| Homepage gallery interaction (`cPanel dashboard` → `Instance monitoring` → close) | `ev_1b6b2847f2916fed2041cf98a54ba7ec6e52cd6b2f775e9355531dea699ef6e9` | Controlled replay | Derived from captured DOM/accessibility | Complete; all three UI actions succeeded; each step retained DOM, accessibility, and screenshot. |
| `https://cpanelredismanager.com/index.php` recheck | `ev_f4a3084c92dba10fd90f09992df550cc7ae6c091597d4a0734453f4b3300a576` | Controlled replay | Derived from captured DOM/accessibility and selected response bodies | Initial page load completed; DOM/accessibility captured; homepage accessibility text 29,291 characters. No screenshot or interaction was part of this recheck. |
| `https://cpanelredismanager.com/documentation.php` recheck | `ev_1500bf08ac1424161faba2c3777a06f188ecd7f1d7db2ab3176889b5873a4a8c` | Controlled replay | Derived from captured DOM/accessibility | Initial page load completed; documentation accessibility text 62,216 bytes. No screenshot or interaction was part of this recheck. |
| `https://cpanelredismanager.com/upgrade.php` recheck | `ev_83aaedeccbd07420cf73c66616c1d0dbda456366dfc7f9a68d601825b37de125` | Controlled replay | Derived from captured DOM/accessibility | Initial page load completed; update-page accessibility text 8,901 characters. No screenshot or interaction was part of this recheck. |
| `https://cpanelredismanager.com/index.php` (2026-11-21 recheck) | `ev_a2982e6eb1f0445d33a3cea1c0cc296cca904e9bec85454d9b95ac5af5f2d5f3` | Controlled replay | Derived from captured DOM/accessibility | Chromium 158.0.8127.36; complete within the requested view; 29,316-byte accessibility tree, DOM, final viewport screenshot, and 9 page-scoped network transactions; no response bodies or interaction. |
| `https://cpanelredismanager.com/documentation.php` (2026-11-21 recheck) | `ev_c15819e47192f23b2fa0e4404fcd0162afb8a14e50b0d0e78bc0397909c5f462` | Controlled replay | Derived from captured DOM/accessibility | Chromium 158.0.8127.36; complete within the requested view; 62,216-byte accessibility tree and DOM; no screenshot, response bodies, or interaction. |
| `https://cpanelredismanager.com/upgrade.php` (2026-11-21 recheck) | `ev_697e908b472dcb9474366dddd4c6c8e272324edb037b9fb3f469555bc436ce84` | Controlled replay | Derived from captured DOM/accessibility | Chromium 158.0.8127.36; complete within the requested view; 8,904-byte accessibility tree and DOM; no screenshot, response bodies, or interaction. |
| `https://cpanelredismanager.com/index.php` (2026-11-22 recheck) | `ev_1e6930ee95f563411b0e5e01f90a7eb9e9d4401ca6144430d14cce46b420e2ae` | Controlled replay | Derived from captured DOM/accessibility | Chromium 158.0.4370.33; complete; 29,316-byte accessibility tree, DOM, and viewport screenshot; page reports v2.6.11. |
| `https://cpanelredismanager.com/documentation.php` (2026-11-22 recheck) | `ev_609d758796f6800cd7dbb3f16cbe068b3e594a4e9499a91e95fb866dcfd53ac0` | Controlled replay | Derived from captured DOM/accessibility | Chromium 158.0.4370.33; complete; 62,216-byte accessibility tree, DOM, and viewport screenshot; page reports v2.6.11. |
| `https://cpanelredismanager.com/upgrade.php` (2026-11-22 recheck) | `ev_1ff2bca3b4e60ff819d73ac299e9bdd40b80bd7b7804f7c392b6c4908c22d9b9` | Controlled replay | Derived from captured DOM/accessibility | Chromium 158.0.4370.33; complete; 8,904-byte accessibility tree, DOM, and viewport screenshot; page reports v2.6.11. |

## What this does not establish

- The feature descriptions are claims made by the public website, not independently verified implementation facts. REA's controlled replay confirms the rendered page and accessible interactions at capture time, not hidden server behavior.
- No authenticated cPanel/WHM screens, installed package, server-side source, API, license service, or billing integration was inspected.
- Page content does not reveal every branch, permission check, failure state, race condition, or error message in the actual plugin.
- The overview gallery documents twelve screenshots (the first cPanel dashboard is reused in a hero and the gallery); the repository's four screenshots are original ORM prototype captures, not screenshots of the vendor product.
- REA's controlled replay records the rendered browser view and its limitations; it is not a packet-level recording or proof of the page's underlying server implementation.

For those reasons, the PHP UI in this repository remains a safe, data-backed prototype. Features that could change Redis processes, files, credentials, accounts, packages, or server policy require an implementation review against the actual cPanel/WHM APIs and security model before being enabled.
