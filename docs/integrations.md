# Integration matrix

The reference product documents a broad range of application clients. The authenticated cPanel connection panel now exposes account-specific Unix-socket values and copyable helpers for the application integrations listed below. ORM can optionally generate and rotate the Redis instance password, but it does not write application settings or transfer the secret into helper snippets; owners configure applications through each application's supported protected configuration path.

Step-by-step connection examples are collected in the [application guides](guides/applications/README.md). They use placeholders and describe integration steps; they do not configure customer applications.

The cPanel preflight reports whether PhpRedis is loaded in the PHP runtime serving the ORM page. It cannot identify the PHP version or extension set selected by each domain, and it does not test application connectivity. Enable PhpRedis in a domain's own runtime only when the selected PHP client requires it; Node.js and Python clients do not use this extension.

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
| Hosting package and reseller policy | Package eligibility, memory/retention ceilings, reseller quotas, user exposure | Root WHM can set package availability, memory ceilings, snapshot retention, per-OWNER instance and aggregate-memory quotas, policy mode, and cPanel exposure. |
| Provider branding | Product name, PNG logo, HTTPS support link, four-color palettes and presets, footer visibility | Root WHM validates and previews branding; cPanel receives only those display fields through the account-authenticated broker. |
| WHMCS | Billing lifecycle events | Future, optional adapter; must remain decoupled from core |
| Provider hook events | Billing/automation reactions | Optional signed event delivery is implemented in the repository and disabled by default. Receivers must verify HMAC signatures, enforce timestamps, and deduplicate event IDs. Disposable-host release validation remains required. See [the provider event guide](guides/provider-events.md) and [issue #143](https://github.com/aivanov2-godaddy/open-redis-manager/issues/143). |

## Credential rules

- Never put a real credential in a URL, browser storage, app logs, or an issue report.
- AUTH is off by default. The generated password appears only in the successful explicit rotation response; status, diagnostics and support exports never return it. If it is lost, rotate again.
- A successful rotation restarts the cache and revokes the previous password after verification. Application clients may fail until their protected configuration is updated; complete that update immediately. A failed verification attempts to restore the prior config and service.
- Samples use placeholders unless the user asks to reveal real connection values.
