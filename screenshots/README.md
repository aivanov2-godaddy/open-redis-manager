# ORM prototype screenshots

Screenshots below were captured from the local PHP prototype using sample data and the current ORM brand mark. None are screenshots from the commercial reference product.

| Image | Surface | Capture |
|---|---|---|
| [ORM logo redesign](orm-logo.png) | Open control loop and dimensional cache stack in the ORM red, previewed at full size and interface-icon scale | 1200 × 900; [HTML preview](previews/orm-logo.html) |
| [cPanel dashboard](cpanel-dashboard.png) | Account status, usage, setup checklist and trend | 1500 × 1200 |
| [cPanel setup presets](cpanel-presets.png) | Initial cache setup with five account-safe workload profiles | 1440 × 1000 |
| [cPanel configuration](cpanel-configuration.png) | Bounded memory, eviction, client and timeout controls with a cache eviction warning | 1440 × 1100 |
| [cPanel backups and restore](cpanel-backups-restore.png) | Synthetic account-scoped snapshot list, restore controls and recovery warning | 1440 × 1100; [HTML preview](previews/cpanel-backups-restore.html) |
| [cPanel live monitoring](cpanel-monitoring.png) | Current memory, clients, uptime, operation rate and cache hit ratio | 1440 × 1000 |
| [cPanel hourly metrics history](cpanel-metrics-history.png) | Responsive 24-hour hourly memory, client and hit-ratio trends with range selection | 1440 × 1100 |
| [cPanel diagnostics](orm-diagnostics.png) | Allowlisted support JSON preview, explicit download, and privacy exclusions | 1440 × 1100; [HTML preview](previews/cpanel-diagnostics.html) |
| [cPanel stale monitoring preview](previews/cpanel-monitoring-stale.html) | Stopped service with last-known metrics, stale marker and 30-day retention explanation | HTML preview; image capture pending |
| [cPanel connection details](cpanel-connection-details.png) | Private socket path, authentication mode, and seven account-specific copyable client/application helpers | 1440 × 2650; [HTML preview](previews/connection-details.html) |
| [WHM fleet](whm-fleet.png) | Root-only account inventory with service and per-account snapshot controls | 1440 × 1100 |
| [WHM fleet preview](previews/whm-fleet.html) | Synthetic account list with service actions and individual snapshot/restore results | HTML preview |
| [WHM overview](whm-overview.png) | Fleet summary, trend and backend state | 1500 × 1200 |
| [WHM accounts](whm-accounts.png) | Searchable account list and health | 1500 × 1200 |
| [WHM security](whm-security.png) | Security signals and report-only policy | 1500 × 1200 |
| [WHM package policy](whm-package-policy.png) | Root-only package enablement, memory ceilings, and snapshot retention | 1200 × 1125; [HTML preview](previews/whm-package-policy.html) |

The dashboard and WHM overview/accounts/security images are nonfunctional prototype screens. The cPanel setup image is a static preview rendered from [its HTML fixture](previews/cpanel-presets.html), with synthetic data. The cPanel configuration image is a static preview rendered from [its HTML fixture](previews/cpanel-configuration.html), with synthetic settings. The cPanel monitoring and hourly history images are static previews rendered from [their HTML fixture](previews/cpanel-monitoring.html); the stale-state design is in a [synthetic HTML preview](previews/cpanel-monitoring-stale.html), with image capture pending. The cPanel backup and restore screenshot is rendered from its [synthetic HTML preview](previews/cpanel-backups-restore.html). The connection-details image is a static preview rendered from [its HTML fixture](previews/connection-details.html). The WHM account-action and snapshot design is rendered from its [synthetic HTML preview](previews/whm-fleet.html). These previews are not connected to cPanel or Redis/Valkey.

The cPanel diagnostics screenshot is a static, synthetic preview rendered from [its HTML fixture](previews/cpanel-diagnostics.html). Its sample JSON does not contain account or service secrets and does not connect to a live cPanel account.

The provider package policy image is a static UI preview rendered from [its HTML fixture](previews/whm-package-policy.html). Package names and limits are sample values and are not read from a live WHM server.
