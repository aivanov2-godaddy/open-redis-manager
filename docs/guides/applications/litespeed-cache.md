# LiteSpeed Cache for WordPress

LiteSpeed Cache can use a Redis-compatible object cache when the required WordPress plugin and PHP Redis client are available. The web server's cache features and Redis object cache are separate configuration layers.

## Setup checklist

1. Enable the Redis extension for the PHP version selected by the site. On CloudLinux, use PHP Selector; on EasyApache, install the matching PHP extension package through the server administrator.
2. Confirm that the LiteSpeed Cache plugin version exposes Redis object-cache settings.
3. In LiteSpeed Cache → Cache → Object, choose Redis and enter the socket path shown by ORM as Host, `0` as Port, and the selected database ID (normally `0`). Leave Password blank when AUTH is disabled. If you enable AUTH in ORM, enter the generated password through the plugin's protected setting.
4. Save the settings, enable object caching, and confirm the plugin reports a connected backend.
5. Test cache invalidation for content updates and WooCommerce checkout/cart flows before enabling the configuration broadly.

Confirm that your LiteSpeed Cache version supports Redis over a Unix socket and that its PHP runtime can access the cPanel account's socket, especially when CageFS or a container is enabled. The LiteSpeed documentation describes using the socket path as Host and port `0` for Unix sockets. The example does not write application configuration automatically.

See LiteSpeed's current [object-cache guide](https://docs.litespeedtech.com/lscache/lscwp/admin/) and [Object settings reference](https://docs.litespeedtech.com/lscache/lscwp/cache/).

## Troubleshooting

- Check that the selected PHP runtime has the Redis extension, not only the server-level Redis process.
- Recheck the socket path and port `0`. If ORM AUTH is enabled, verify that the plugin's password setting matches the current generated password.
- If the client is available but connections fail, ask the host administrator to review the account instance and local network namespace.
- Treat a successful object-cache connection as separate from page-cache status.
