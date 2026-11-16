# WordPress and WooCommerce

WordPress object-cache integrations use Redis to reuse values that would otherwise be fetched or rebuilt repeatedly. WooCommerce can benefit from the same object-cache path, but checkout correctness and plugin compatibility must be verified on the specific site.

## Setup

1. Initialize the account's ORM instance and copy its private socket path from cPanel.
2. Install a maintained WordPress Redis object-cache plugin that supports your PHP/runtime stack.
3. Add the connection values using the plugin's documented settings. Some plugins read constants from `wp-config.php`; supported names differ by plugin.
4. Enable the plugin's object cache, then verify its status page and test both logged-in and logged-out requests.
5. Confirm that cache invalidation works when posts, products, inventory, or settings change.

For the Redis Object Cache plugin, use the account-private Unix socket settings below:

```php
define( 'WP_REDIS_SCHEME', 'unix' );
define( 'WP_REDIS_PATH', '/var/lib/orm-instances/<your-cpanel-account>/redis.sock' );
define( 'WP_REDIS_DATABASE', 0 );
define( 'WP_REDIS_PREFIX', 'replace_with_site_prefix:' );
```

These names are supported by the [Redis Object Cache plugin](https://github.com/rhubarbgroup/redis-cache). Put them before WordPress loads `wp-settings.php`. AUTH is off by default; if enabled in ORM, configure `WP_REDIS_PASSWORD` from the protected `ORM_REDIS_PASSWORD` environment variable supported by your deployment. Use the path shown by your cPanel account rather than copying the placeholder. Keep `wp-config.php` readable only by the site owner and trusted administrators. WooCommerce uses the same WordPress object-cache integration; verify cart, checkout, inventory, and invalidation behavior before enabling it broadly.

## Verification

- The plugin reports a successful Redis connection.
- A page request produces cache hits after the first request.
- Publishing or updating content invalidates the relevant cache.
- Checkout, cart, account, and session behavior remains correct under the site's normal test procedure.

ORM does not make WordPress faster by itself. The site must use a compatible object-cache plugin, and the effect depends on its workload.

See also: [WordPress persistent object cache](https://developer.wordpress.org/advanced-administration/performance/cache/).
