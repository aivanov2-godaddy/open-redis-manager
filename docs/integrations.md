# Integration matrix

The reference product documents a broad range of application clients. Open Redis Manager will expose connection details and samples while leaving application-specific cache behavior to each application.

| Integration | Use case | Planned helper |
|---|---|---|
| WordPress | Persistent object cache | Host/port/password configuration and setup checklist |
| LiteSpeed Cache | WordPress object cache | Compatible connection field guide and extension preflight |
| WooCommerce | Catalog, cart and object caching | WordPress setup plus checkout caution notes |
| Laravel | Cache, sessions, queues and rate limiting | Environment variables and cache/session configuration example |
| Magento | Cache and session storage | Connection prerequisites and validation checklist |
| PHP | Custom app cache/session use | `phpredis` / compatible client availability check and minimal example |
| Node.js | Application cache and sessions | `redis` client example |
| Python | Application cache and sessions | `redis-py` example |
| Custom APIs and dashboards | Hot data and repeated computation | Generic host/port/database setup |
| Forums and membership sites | Sessions and repeated lookups | Generic session integration guidance |
| CRMs and admin applications | Dashboard and record cache | Generic cache integration guidance |
| CloudLinux PHP Selector | Extension visibility per PHP version | Admin checklist for enabling the PHP Redis extension |
| CageFS | User runtime visibility | Admin checklist for refreshing the environment after extension changes |
| EasyApache | PHP extension packages | Match extension packages to enabled PHP versions |
| cPanel UAPI | Account-safe user operations | Planned account-scoped API adapter |
| WHM API | Privileged administration | Planned WHM ACL-protected adapter |
| Hosting package system | Package eligibility and limits | Planned provider policy adapter |
| WHMCS | Billing lifecycle events | Future, optional adapter; must remain decoupled from core |
| Provider hook events | Billing/automation reactions | Future signed, replay-safe event interface |

## Credential rules

- Never put a real credential in a URL, browser storage, app logs, or an issue report.
- Mask secrets on screen and in exports until the account owner explicitly reveals or copies them.
- Rotate credentials through a staged update with a rollback path so running application clients do not get stuck with a mismatched value.
- Samples use placeholders unless the user asks to reveal real connection values.
