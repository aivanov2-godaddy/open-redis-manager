# Plain PHP with phpredis

The phpredis extension exposes a `Redis` client class. First enable the extension in the PHP version used by the website, then connect using the account-specific ORM Unix socket. AUTH is off by default; if enabled in cPanel, authenticate with the generated password from a protected application environment variable.

```php
<?php
$redis = new Redis();
$redis->connect('/var/lib/orm-instances/<your-cpanel-account>/redis.sock');
$redis->select(0);

$redis->set('example:key', 'value', 60);
$value = $redis->get('example:key');
```

Use the path shown by the cPanel account rather than copying the placeholder. Applications should handle connection errors and use key prefixes so one application's cache keys do not collide with another data set in the same account.

The example uses a short-lived cache value. Use application-specific expiration and invalidation rules; Redis cache content should be safe to rebuild unless the operator has deliberately chosen a persistence strategy.

See the [phpredis project documentation](https://github.com/phpredis/phpredis) for supported methods and options. Its maintainers also document a [Unix socket connection example](https://github.com/phpredis/phpredis/issues/1664).

ORM-managed instances disable TCP and rely on the account-owned socket directory for access control. This example has not yet been validated across cPanel PHP versions.
