# Integration matrix

The reference product documents a broad range of application clients. The authenticated cPanel connection panel now exposes account-specific Unix-socket values and copyable helpers for the application integrations listed below. Helpers do not install clients, edit application files, enable application features, or manage application secrets; owners make those changes through each application's supported configuration path.

Step-by-step connection examples are collected in the [application guides](guides/applications/README.md). They use placeholders and describe integration steps; they do not configure customer applications.

| Integration | Use case | Guide and helper |
|---|---|---|
| WordPress | Persistent object cache | [Object-cache setup](guides/applications/wordpress.md) |
| LiteSpeed Cache | WordPress object cache | [LiteSpeed setup and runtime checklist](guides/applications/litespeed-cache.md) |
| WooCommerce | Catalog, cart and object caching | [WordPress setup and checkout checks](guides/applications/wordpress.md) |
| Laravel | Cache, sessions, queues and rate limiting | [Laravel environment example](guides/applications/laravel.md) |
| Magento | Cache backend | [Version-aware Magento setup](guides/applications/magento.md) |
| PHP | Custom app cache/session use | [phpredis example](guides/applications/php.md) |
| Node.js | Application cache and sessions | [node-redis example](guides/applications/nodejs.md) |
| Python | Application cache and sessions | [redis-py example](guides/applications/python.md) |
| Custom APIs and dashboards | Hot data and repeated computation | [Generic integration checklist](guides/applications/generic-apps.md) |
| Forums and membership sites | Sessions and repeated lookups | [Generic integration checklist](guides/applications/generic-apps.md) |
| CRMs and admin applications | Dashboard and record cache | [Generic integration checklist](guides/applications/generic-apps.md) |
| CloudLinux PHP Selector | Extension visibility per PHP version | [LiteSpeed setup checklist](guides/applications/litespeed-cache.md); administrator must enable the PHP Redis extension for the site's selected runtime |
| CageFS | User runtime visibility | Admin checklist for refreshing the environment after extension changes |
| EasyApache | PHP extension packages | Match extension packages to enabled PHP versions |
| cPanel UAPI | Account-safe user operations | Planned account-scoped API adapter |
| WHM API | Privileged administration | Planned WHM ACL-protected adapter |
| Hosting package system | Package eligibility and limits | Root WHM can set package availability, memory ceilings, and snapshot retention. Reseller quotas remain planned. |
| WHMCS | Billing lifecycle events | Future, optional adapter; must remain decoupled from core |
| Provider hook events | Billing/automation reactions | Future signed, replay-safe event interface |

## Credential rules

- Never put a real credential in a URL, browser storage, app logs, or an issue report.
- Mask secrets on screen and in exports until the account owner explicitly reveals or copies them.
- Rotate credentials through a staged update with a rollback path so running application clients do not get stuck with a mismatched value.
- Samples use placeholders unless the user asks to reveal real connection values.
