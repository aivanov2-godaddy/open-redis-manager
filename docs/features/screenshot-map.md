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
| WHM package policy | Per-package service availability and capacity limits. |
| WHM branding | Provider identity, colors and a cPanel preview. |
| [ORM fleet inventory](../../screenshots/whm-fleet.png) | Synthetic example of the original root-only account status table. |
| [WHM account action preview](../../screenshots/previews/whm-fleet.html) | Synthetic account table with start/stop/restart controls, status, confirmation and audit notes; PNG capture pending. |
| [ORM stale metrics preview](../../screenshots/previews/cpanel-monitoring-stale.html) | Synthetic stopped-service view with last-known values, stale marker and sample age guidance; image capture is pending. |

ORM prototype captures are original implementations in [`/screenshots`](../../screenshots/README.md). The connection-details capture demonstrates the private Unix-socket path and PhpRedis example with synthetic data; it does not connect to a live cPanel account or cache service. Other prototype screens also use demonstration data.
