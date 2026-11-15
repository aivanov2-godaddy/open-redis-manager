# Node.js

The `redis` npm package supports a Redis-compatible endpoint. Install dependencies through the application's normal package workflow and keep the secret in an environment variable.

```js
import { createClient } from 'redis';

const client = createClient({
  socket: {
    host: process.env.ORM_REDIS_HOST ?? '127.0.0.1',
    port: Number(process.env.ORM_REDIS_PORT),
  },
  password: process.env.ORM_REDIS_PASSWORD,
  database: Number(process.env.ORM_REDIS_DATABASE ?? 0),
});

client.on('error', (error) => {
  // Send a redacted error class/message to application logging.
  console.error('Redis connection error', error.name);
});

await client.connect();
await client.set('example:key', 'value', { EX: 60 });
const value = await client.get('example:key');
await client.quit();
```

Ensure the application's runtime supports ES modules or adapt the import to its module format. Do not log configuration objects that contain the password.

See the [node-redis client configuration guide](https://github.com/redis/node-redis/blob/master/docs/client-configuration.md) for supported connection options.
