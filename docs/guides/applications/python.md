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

See the [redis-py client documentation](https://redis.readthedocs.io/) for current connection and retry options.
