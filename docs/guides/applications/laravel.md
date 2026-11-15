# Laravel

Laravel can use Redis for cache entries, sessions, queues, rate limiting, and other supported framework features. Select only the features the application intends to use.

## Environment values

Add the instance values to the application's protected environment configuration:

```dotenv
CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis

REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=replace-with-the-account-secret
REDIS_PORT=12345
REDIS_DB=0
```

The phpredis extension or a compatible PHP client must be enabled in the runtime used by the application. Laravel versions may use different configuration defaults; compare this example with the app's `config/database.php` and the [Laravel Redis guide](https://laravel.com/docs/redis). That guide documents `REDIS_CLIENT`, host, username, password, port, database, and per-connection cache database configuration.

After changing configuration, use the application's normal deployment process to clear and rebuild cached configuration. Test cache reads/writes, session continuity, and queue workers separately. Restart long-running workers only through the application's deployment procedure.

Never paste a production `.env` file into a support ticket or diagnostics bundle.
