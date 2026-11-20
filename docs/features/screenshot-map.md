# Reference screenshot map

The reference site uses these product surfaces to explain its cPanel and WHM scope. The descriptions below are paraphrased from public accessible text; images and logos remain with their owner and are not redistributed here.

The public gallery has three cPanel and nine WHM screenshots. Its cards open an accessible lightbox with previous, next, and close controls. The cPanel dashboard is also reused as a hero image. See the [REA evidence ledger](../rea-evidence.md) for capture identity and limitations.

| Surface | Information shown or workflow conveyed |
|---|---|
| cPanel overview | Service state, endpoint, AUTH controls, memory/database details and lifecycle shortcuts. |
| cPanel monitoring | Latency, memory, connections, uptime, command activity and trend range. |
| cPanel configuration and backups | Workload presets, settings, backup creation and restore. |
| WHM dashboard | Fleet counts, total connections, available memory, backend version and history. |
| WHM account management | Search/filter, per-account status, port, resource use and action links. |
| WHM command console | Select an account, issue a Redis CLI command and read output. |
| WHM backups | Account-specific and fleet snapshot workflows. |
| WHM recovery | Scan results, health actions, restart/config/credential/permission repair. |
| WHM global settings | Defaults, update checks, user CLI visibility and history retention. |
| WHM security | Firewall guidance, local binding and credential rotation. |
| WHM package and reseller policy | Root-only package service availability, memory/retention ceilings, report/warn/enforce mode, exposure tier, reseller usage and quota controls. |
| cPanel exposure tiers | Side-by-side Simple, Developer and Advanced visibility previews; broker authorization remains unchanged. |
| [ORM application preflight](../../screenshots/cpanel-application-discovery.png) | Sample-data cPanel view of service setup checks and possible application matches; connection state is clearly unverified. |
| [WHM branding](../../screenshots/whm-provider-branding.png) | Provider identity, four honestly labelled theme colors, brand palettes, and a synthetic cPanel preview. |
| [ORM fleet inventory](../../screenshots/whm-fleet.png) | Synthetic root-only account table with service controls and per-account snapshot/restore UI. |
| [WHM account action preview](../../screenshots/previews/whm-fleet.html) | Synthetic account table with service controls, snapshot states, restore confirmation and per-account result messaging. |
| [ORM stale metrics preview](../../screenshots/previews/cpanel-monitoring-stale.html) | Synthetic stopped-service view with last-known values, stale marker and sample age guidance; image capture is pending. |
| [cPanel connection helpers](../../screenshots/cpanel-connection-details.png) | Synthetic account page with seven socket-based client and application settings, per-example copy controls, and security/runtime notes. |
| [ORM health guidance](../../screenshots/cpanel-health-guidance.png) | Synthetic account-scoped advisory for configured memory/client limits and cumulative hit ratio; thresholds are not performance guarantees. |
| [ORM diagnostics preview](../../screenshots/orm-diagnostics.png) | Synthetic cPanel support panel with a credential-redacted JSON preview and explicit download action. |
| [WHM audit log](../../screenshots/whm-audit-log.png) | Root-only UTC filters, source coverage, normalized events, and JSON export using synthetic sample data. |
| [WHM security report](../../screenshots/whm-security-report.png) | Synthetic report-only findings with configurable threshold controls, counter-rate windows, partial coverage, and explicitly unknown authentication signals. The preview crosses the sample thresholds to show advisory warnings only. |
| [cPanel Jupiter v4 icon preview](../../screenshots/previews/cpanel-icons-v4-preview.png) | Local preview of the exact 48×48 PNGs registered directly for the group and launcher, using the approved brand mark. This is an asset preview, not a live authenticated cPanel capture. |
| [cPanel Jupiter generated-sprite preview](../../screenshots/previews/cpanel-jupiter-live-sprite-preview.png) | Local render of the group and launcher entries from the test server's generated Jupiter sprite after its CSS cache key was synchronized. The artwork is sourced from the live sprite; this is not a browser screenshot. |

ORM prototype captures are original implementations in [`/screenshots`](../../screenshots/README.md). The connection-details capture demonstrates the private Unix-socket path and PhpRedis example with synthetic data; it does not connect to a live cPanel account or cache service. Other prototype screens also use demonstration data.
