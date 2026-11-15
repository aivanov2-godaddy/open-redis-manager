# Plain PHP with phpredis

The phpredis extension exposes a `Redis` client class. First enable the extension in the PHP version used by the website, then connect using the account-specific ORM values.

```php
<?php
$redis = new Redis();
$redis->connect('127.0.0.1', 12345, 1.5);
$redis->auth(getenv('ORM_REDIS_PASSWORD'));
$redis->select(0);

$redis->set('example:key', 'value', 60);
$value = $redis->get('example:key');
```

Load the password from a protected environment/configuration source. Avoid hard-coding it into a file served from the document root. Applications should handle connection errors and use key prefixes so one application's cache keys do not collide with another data set in the same account.

The example uses a short-lived cache value. Use application-specific expiration and invalidation rules; Redis cache content should be safe to rebuild unless the operator has deliberately chosen a persistence strategy.

See the [phpredis project documentation](https://github.com/phpredis/phpredis) for supported methods and options.
