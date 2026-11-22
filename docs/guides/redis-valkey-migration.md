# Redis to Valkey migration

ORM provides a root-only, one-account migration from an existing ORM-managed Redis instance to Valkey. This is an early-development operation and has not passed disposable cPanel lifecycle validation.

## Supported range

- Source: Redis 6.2.x through Redis 7.2.x.
- Target: Valkey 7.2.0 or newer, with `valkey-server`, `valkey-cli`, and `valkey-check-rdb` available in a trusted system path.
- The account must have a running ORM-managed Redis instance and verified root-controlled snapshot storage.
- Other Redis distributions, unmanaged instances, replication, clustered or multi-node deployments, and Redis 7.4+ are not supported by this operation.

The Redis version limit uses `CLIENT PAUSE ... WRITE` for the write barrier and excludes releases with incompatible RDB formats. See Valkey's [migration guidance](https://valkey.io/topics/migration/) and Redis's [`CLIENT PAUSE` command](https://redis.io/docs/latest/commands/client-pause/).

## Before starting

Stop or pause every application component that writes to the cache, including web workers, queue consumers, scheduled jobs, and external services. Read-only connections can also be interrupted when ORM stops Redis. In WHM, acknowledge that writers are quiesced and confirm the account-specific migration. Keep writers stopped until Valkey reports healthy and the application has been checked.

ORM adds an account operation lock shared with start, stop, restart, configuration, snapshot, and restore operations. It then pauses Redis writes, creates a safety RDB, validates it with the Valkey checker, verifies that the per-database key and expiry counts have not changed, and refuses to proceed if the bounded pause window is nearly exhausted. ORM stops the account service, installs the validated snapshot, atomically changes the root-controlled backend manifest, starts Valkey, checks `PING`, and compares key and expiry counts again.

## Failure and recovery

When a failure occurs after the Redis service stops, ORM attempts to validate the retained snapshot with the Redis checker, restore it, reinstate the Redis manifest, start Redis, and verify service state and key/expiry counts. The transaction guard also handles unexpected exceptions and an ambiguous pause-command reply: while the original Redis service is still active it attempts to clear the write pause; after a stop or backend switch it uses the retained snapshot to restore and verify Redis. A failed or unverified recovery is reported as requiring manual recovery. The snapshot ID appears in the WHM result and remains in the account's bounded snapshot list.

Count checks cannot prove that every key value is identical. If the result is uncertain, keep application writers paused, inspect the account and the retained snapshot, and do not repeat the migration blindly. ORM does not read or log Redis keys or values. The operation is per account and does not change the server-wide backend default.

## Release status

Protocol, broker authorization, account resolution, audit, WHM confirmation, and manager-level version/snapshot/rollback guards are implemented. Required disposable-host work remains: exercise supported Redis/Valkey combinations, verify write-quiescence and downtime behavior, inject failures at each file/service transition, and validate recovery and uninstall. Do not use on production systems until those gates are complete.
