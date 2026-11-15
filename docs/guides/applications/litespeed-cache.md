# LiteSpeed Cache for WordPress

LiteSpeed Cache can use a Redis-compatible object cache when the required WordPress plugin and PHP Redis client are available. The web server's cache features and Redis object cache are separate configuration layers.

## Setup checklist

1. Enable the Redis extension for the PHP version selected by the site. On CloudLinux, use PHP Selector; on EasyApache, install the matching PHP extension package through the server administrator.
2. Confirm that the LiteSpeed Cache plugin version exposes Redis object-cache settings.
3. Enter the ORM host, port, database, and password in the plugin's object-cache settings. Use the per-account values from cPanel.
4. Save the settings, enable object caching, and confirm the plugin reports a connected backend.
5. Test cache invalidation for content updates and WooCommerce checkout/cart flows before enabling the configuration broadly.

The exact setting names vary by LiteSpeed Cache release. Keep the password in the plugin's protected configuration and out of public diagnostics.

See LiteSpeed's current [object-cache guide](https://docs.litespeedtech.com/lscache/lscwp/admin/) and [Object settings reference](https://docs.litespeedtech.com/lscache/lscwp/cache/).

## Troubleshooting

- Check that the selected PHP runtime has the Redis extension, not only the server-level Redis process.
- Recheck the port and password in ORM; do not assume port `6379` for an account instance.
- If the client is available but connections fail, ask the host administrator to review the account instance and local network namespace.
- Treat a successful object-cache connection as separate from page-cache status.
