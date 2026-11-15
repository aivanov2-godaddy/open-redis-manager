# Python

The `redis-py` client can connect to an ORM account instance. Install the package in the application's isolated Python environment and supply the connection values through protected environment variables.

```python
import os
import redis

client = redis.Redis(
    host=os.environ.get("ORM_REDIS_HOST", "127.0.0.1"),
    port=int(os.environ["ORM_REDIS_PORT"]),
    password=os.environ["ORM_REDIS_PASSWORD"],
    db=int(os.environ.get("ORM_REDIS_DATABASE", "0")),
    decode_responses=True,
    socket_connect_timeout=1.5,
)

client.set("example:key", "value", ex=60)
value = client.get("example:key")
```

Catch `redis.exceptions.RedisError` at an application boundary and emit redacted diagnostics. Avoid printing environment variables or connection URLs that include credentials.

See the [redis-py client documentation](https://redis.readthedocs.io/) for current connection and retry options. The official [Redis client source](https://github.com/redis/redis-py/blob/master/redis/client.py) defines the `unix_socket_path` option.

## Connect to an ORM-managed instance

The ORM cPanel page shows the socket path for your provisioned instance. Use redis-py's Unix socket option:

```python
import redis

client = redis.Redis(
    unix_socket_path="/var/lib/orm-instances/<your-cpanel-account>/redis.sock",
    db=0,
)
client.ping()
```

ORM-managed instances use Unix socket permissions and do not configure Redis AUTH or expose TCP. This example has not yet been validated across cPanel Python application environments.
