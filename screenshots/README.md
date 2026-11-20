# ORM prototype screenshots

Screenshots below are local prototype captures using sample data. The logo, cPanel feature previews, and WHM policy/fleet previews use the current ORM brand mark; the standalone dashboard and WHM summary mockups are earlier static concepts. None are screenshots from the commercial reference product.

| Image | Surface | Capture |
|---|---|---|
| [ORM logo](orm-logo.png) | White three-tier cache cube with an inset keyspace on a Redis-red tile, shown at full size and interface-icon scale | [HTML preview](previews/orm-logo.html); [renderable SVG composition](previews/orm-logo-showcase.svg) |
| [cPanel registration icon assets](previews/cpanel-registration-icons.png) | Transparent Redis-red cache-tier outlines adapted for cPanel's 48×48 Jupiter group and launcher SVGs; local asset preview, not a live browser capture | Source assets: [`orm-group.svg`](../packaging/cpanel/icons/orm-group.svg) and [`orm-feature.svg`](../packaging/cpanel/icons/orm-feature.svg) |
| [cPanel dashboard](cpanel-dashboard.png) | Account status, usage, setup checklist and trend | 1500 × 1200 |
| [cPanel application discovery](cpanel-application-discovery.png) | On-demand app marker results and honest connection preflight | Static sample-data preview; [HTML source](previews/cpanel-application-discovery.html) |
| [cPanel exposure tiers](cpanel-exposure-tiers.png) | Simple, Developer and Advanced feature visibility with the same account boundary | Static comparison preview; [HTML source](previews/cpanel-exposure-tiers.html) |
| [cPanel setup presets](cpanel-presets.png) | Initial cache setup with five account-safe workload profiles | 1440 × 1000 |
| [cPanel configuration](cpanel-configuration.png) | Bounded memory, eviction, client and timeout controls with a cache eviction warning | 1440 × 1100 |
| [cPanel backups and restore](cpanel-backups-restore.png) | Synthetic account-scoped snapshot list, restore controls and recovery warning | 1440 × 1100; [HTML preview](previews/cpanel-backups-restore.html) |
| [cPanel live monitoring](cpanel-monitoring.png) | Current memory, clients, uptime, operation rate, cache hit ratio, and optional AUTH posture | 1440 × 1054 |
| [cPanel hourly metrics history](cpanel-metrics-history.png) | Responsive 24-hour hourly memory, client and hit-ratio trends with range selection | 1440 × 1100 |
| [cPanel diagnostics](orm-diagnostics.png) | Allowlisted support JSON preview, explicit download, and privacy exclusions | 1440 × 1100; [HTML preview](previews/cpanel-diagnostics.html) |
| [cPanel health guidance](cpanel-health-guidance.png) | Synthetic advisory warnings for memory, connected clients, and cumulative hit ratio | Static sample-data preview; [HTML source](previews/cpanel-health-guidance.html) |
| [cPanel stale monitoring preview](previews/cpanel-monitoring-stale.html) | Stopped service with last-known metrics, stale marker and 30-day retention explanation | HTML preview; image capture pending |
| [cPanel connection details](cpanel-connection-details.png) | Private socket path, optional AUTH status/rotation guidance, and seven account-specific copyable client/application helpers | 1440 × 1505; [HTML preview](previews/connection-details.html) |
| [WHM fleet](whm-fleet.png) | Root-only account inventory, page-scoped health counts, read-only recovery scans and per-account controls | 1440 × 1387; [HTML preview](previews/whm-fleet.html) |
| [WHM Redis-to-Valkey migration](whm-redis-valkey-migration.png) | Synthetic root WHM row with source/target versions, writer-quiescence acknowledgement and snapshot rollback guidance | 1440 × 1000; [SVG source](previews/whm-redis-valkey-migration.svg) |
| [WHM fleet preview](previews/whm-fleet.html) | Synthetic account list with service actions and individual snapshot/restore results | HTML preview |
| [WHM read-only diagnostics](whm-fleet-diagnostics.png) | Synthetic root-only account row and the validated read-only metrics result with privacy boundary | 1440 × 1100; [SVG preview](previews/whm-fleet-diagnostics.svg) |
| [WHM overview](whm-overview.png) | Fleet summary, trend and backend state | 1500 × 1200 |
| [WHM accounts](whm-accounts.png) | Searchable account list and health | 1500 × 1200 |
| [WHM security](whm-security.png) | Security signals and report-only policy | 1500 × 1200 |
| [WHM security report](whm-security-report.png) | Report-only resource findings, measured counter-rate windows, partial evidence and explicit unknown authentication signals | Static sample-data preview; [HTML source](previews/whm-security-report.html) |
| [WHM package and reseller policy](whm-package-policy.png) | Root-only mode and exposure defaults, package ceilings, reseller usage, and quotas | Static preview; [HTML source](previews/whm-package-policy.html) |
| [WHM provider branding](whm-provider-branding.png) | Provider identity controls and a synthetic live cPanel preview | Static preview; [HTML source](previews/whm-provider-branding.html) |
| [WHM audit log](whm-audit-log.png) | Root-only UTC filters, source coverage status, normalized events, and JSON export | Synthetic sample data; [HTML source](previews/whm-audit-log.html) |
| [WHM signed update preview and job status](whm-update-preview.png) | Root-only signed release preview, explicit asynchronous apply confirmation, queued job status and status lookup | Synthetic release and job values; [HTML source](previews/whm-update-preview.html) |

The dashboard and WHM overview/accounts/security images are nonfunctional prototype screens. The cPanel setup image is a static preview rendered from [its HTML fixture](previews/cpanel-presets.html), with synthetic data. The cPanel configuration image is a static preview rendered from [its HTML fixture](previews/cpanel-configuration.html), with synthetic settings. The cPanel monitoring and hourly history images are static previews rendered from [their HTML fixture](previews/cpanel-monitoring.html); the stale-state design is in a [synthetic HTML preview](previews/cpanel-monitoring-stale.html), with image capture pending. The cPanel backup and restore screenshot is rendered from its [synthetic HTML preview](previews/cpanel-backups-restore.html). The connection-details image is a static preview rendered from [its HTML fixture](previews/connection-details.html). The WHM account-action and snapshot design is rendered from its [synthetic HTML preview](previews/whm-fleet.html). These previews are not connected to cPanel or Redis/Valkey.

The cPanel diagnostics screenshot is a static, synthetic preview rendered from [its HTML fixture](previews/cpanel-diagnostics.html). Its sample JSON does not contain account or service secrets and does not connect to a live cPanel account.

The provider package and reseller policy image is a static UI preview rendered from [its HTML fixture](previews/whm-package-policy.html). Package/reseller names and limits are sample values and are not read from a live WHM server. The exposure comparison is a static preview rendered from [its HTML fixture](previews/cpanel-exposure-tiers.html), with synthetic values.

The WHM diagnostics image is a static synthetic UI composition. It illustrates the guarded per-account action and allowlisted result; it is not a live capture and contains no cPanel account or service data.

The WHM security report image is rendered from a static [synthetic preview](previews/whm-security-report.html). Its rates, counts, and timestamps are invented sample values; the image is not connected to WHM or Redis/Valkey.

The WHM signed update preview image is rendered from a [static HTML fixture](previews/whm-update-preview.html). Its versions, signature result, digest, file actions, and job ID/status are synthetic; it is not connected to a signed release, a public update feed, or a cPanel server.
