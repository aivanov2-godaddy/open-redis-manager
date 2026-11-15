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

ORM does not configure application files automatically. Its planned application detection is read-only and should never change an app's configuration without a separate, explicit user action.
