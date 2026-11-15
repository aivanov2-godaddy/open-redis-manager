# Other applications and APIs

Custom PHP applications, APIs, dashboards, forums, membership sites, and internal tools can use Redis for values that are safe to cache or for session handling supported by the application framework.

## Connection checklist

1. Retrieve the account's host, port, database, and password from ORM.
2. Use a maintained client library for the application's language and version.
3. Load credentials from an environment or secret store with access limited to the application owner.
4. Use a key prefix that identifies the application and environment.
5. Set expiration and invalidation rules appropriate to the data. Do not cache authorization decisions or private data longer than the application can safely tolerate.
6. Handle cache misses and backend timeouts by falling back to the application's source of truth when safe.
7. Measure response time, error rate, cache hit ratio, and backend memory use before and after rollout.

Redis does not provide caching automatically. Application code must decide what to cache, how long it remains valid, and how to recover if the cache is unavailable.
