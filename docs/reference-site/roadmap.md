# Reference site: release themes and roadmap

**Sources:** [home](https://cpanelredismanager.com/index.php), [documentation](https://cpanelredismanager.com/documentation.php), and [upgrade page](https://cpanelredismanager.com/upgrade.php).
**Observed:** 2026-11-21. The pages displayed v2.6.11. The home and documentation pages call the next phase v2.7.x; the update page labels it v2.7.0.

| Version family | Themes shown on the reference site |
|---|---|
| 2.6.11 | Current release at capture time; the site groups security/abuse reporting, AUTH protections, licensing automation, dashboard performance, branding, and stability improvements into the 2.6.x line. |
| 2.7.x / 2.7.0 | Deeper observability and graphs, debug/command visibility, slow-log tooling, a WHM security summary, stronger health scoring, and audit visibility. |
| 2.8.x | Background workers, restart backoff, automatic recovery, orphan cleanup, and maintenance automation. |
| 2.9.x | Profiles/configuration bundles, backup integrity and rollback, cross-server export/import, and signed configuration validation. |
| 2.10.x | REST API, webhooks/automation events, Redis version management, and external Redis integration. |
| 3.0.x | Shared architecture, DirectAdmin, and cluster/Sentinel/scaling work. |

The public page also discusses provider event hooks, package/reseller controls, and broader integrations. These are roadmap and product claims, not an ORM commitment or proof of vendor implementation.

ORM's own plan and evidence remain in [`project/README.md`](../../project/README.md), the [feature catalog](../features/catalog.md), and the [release notes](../release-notes.md). Use the existing [reference release summary](../roadmap-reference.md) for the full paraphrased version-history notes. Do not infer compatibility, release readiness, or priority from the vendor roadmap.
