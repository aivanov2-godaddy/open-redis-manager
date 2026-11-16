# Application connection guides

These guides show how an application can use an ORM-managed Redis-compatible instance after its cPanel owner has configured the connection. ORM provides service controls and connection values; the application still needs a compatible client and its own Redis integration.

Use the host, port, database, and credential from the account's ORM screen. Examples use placeholders only. Keep credentials in the application's protected configuration, never in source control, URLs, browser storage, or support logs. Confirm the exact keys supported by the application's installed version before deploying.

## Guides

- [WordPress](wordpress.md) — object-cache setup.
- [LiteSpeed Cache](litespeed-cache.md) — WordPress object-cache connection.
- [Laravel](laravel.md) — cache, sessions, and queues.
- [Magento](magento.md) — cache backend configuration.
- [PHP with phpredis](php.md) — a direct connection example.
- [Node.js](nodejs.md) — the `redis` client.
- [Python](python.md) — `redis-py`.
- [Other applications and APIs](generic-apps.md) — integration checklist.

## Read-only application discovery

The installed cPanel page offers an on-demand marker scan based on the authenticated account's document roots from cPanel LiveAPI. The scan is capped at 32 roots, 32 path components per root, and a 150 ms cooperative deadline; it checks only a small allowlist of marker paths for WordPress, Laravel, Drupal, Joomla, Magento / Adobe Commerce, and Symfony. It uses filesystem metadata only; it does not open application files, read configuration or secrets, return domain names or paths, execute application code, write into document roots, or change application settings. It rejects observed symbolic-link components, but PHP path-based metadata calls cannot eliminate a concurrent rename or symlink race. The scan runs only when the cPanel PHP process matches the authenticated account's OS identity, limiting the filesystem view to that account's permissions. A detected marker is advisory and does not prove that the application is active or connected to Redis.

The LiveAPI page calls the account-scoped `DomainInfo::domains_data` UAPI operation documented in the [cPanel LiveAPI PHP guide](https://api.docs.cpanel.net/guides/guide-to-the-liveapi-system/guide-to-the-liveapi-system-php-class) and [domain data operation](https://api.docs.cpanel.net/specifications/cpanel.openapi/domain-information/domaininfo-domains_data). Discovery fails closed when the account home, domain metadata, or expected cPanel execution identity cannot be verified. This workflow has not yet been validated across supported cPanel versions, CageFS, or alternate PHP execution models.

The setup preflight reports whether the cache is initialized and running and whether ORM can supply connection details. It deliberately reports application connectivity as unverified; it does not inspect app configuration, test a domain's PHP extension, or guarantee service health.
