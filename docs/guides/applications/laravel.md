# Laravel

Laravel can use Redis for cache entries, sessions, queues, rate limiting, and other supported framework features. Select only the features the application intends to use.

## Environment values

Add the account-private socket values to the application's protected environment configuration. Laravel documents Unix socket connections with the socket path in `REDIS_HOST` and port `0`:

```dotenv
REDIS_CLIENT=phpredis
REDIS_HOST=/var/lib/orm-instances/<your-cpanel-account>/redis.sock
REDIS_PORT=0
REDIS_DB=0
```

The phpredis extension or a compatible PHP client must be enabled in the runtime used by the application. AUTH is off by default. If enabled in ORM, add `REDIS_PASSWORD=${ORM_REDIS_PASSWORD}` and provide that value through the application's protected environment settings. Laravel versions may use different configuration defaults; compare this example with the app's `config/database.php` and the [Laravel Redis guide](https://laravel.com/docs/redis). Configure cache, sessions, queues and rate limiting only if the application needs them.

After changing configuration, use the application's normal deployment process to clear and rebuild cached configuration. Test cache reads/writes, session continuity, and queue workers separately. Restart long-running workers only through the application's deployment procedure.

Never paste a production `.env` file into a support ticket or diagnostics bundle.
