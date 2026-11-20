# Configuration and workload presets

## Presets currently available during setup

The feature inventory includes five starting profiles:

- **WordPress:** object-cache workload.
- **Laravel:** application cache and session/queue usage.
- **Magento:** storefront cache workload.
- **Session cache:** user session storage.
- **Generic:** a neutral baseline for custom applications.

The cPanel initialization form offers all five profiles. The broker accepts only these preset IDs and chooses the initial memory limit server-side:

| Preset | Initial memory limit |
|---|---:|
| WordPress | 48 MiB |
| Laravel | 32 MiB |
| Magento | 64 MiB |
| Session cache | 32 MiB |
| Generic | 64 MiB |

The profile supplies a memory baseline (WordPress 48 MiB, Laravel 32 MiB, Magento 64 MiB, Session 32 MiB, Generic 64 MiB). WHM can lower that value through the 8–64 MiB global default; package memory ceilings still apply during provisioning. WHM also sets the allowlisted eviction policy and 1–16 logical database count for new instances. Profiles request up to 100 clients; the effective package ceiling can lower that value and the database count. All profiles use no client idle timeout and keep persistence disabled. The profile label is stored in the root-owned instance manifest; legacy version 1 manifests continue to read as Generic. Individual user-editable settings can be changed on an existing service as described below, while database count and persistence stay host-controlled.

The profile never accepts raw configuration values from the browser.

## Change an existing instance

The authenticated cPanel page can update four saved settings for the current account:

| Setting | Allowed values |
|---|---|
| Memory limit | 8–64 MiB, in 1 MiB steps |
| Eviction policy | `allkeys-lru`, `allkeys-lfu`, `allkeys-random`, `volatile-lru`, `volatile-lfu`, `volatile-random`, `volatile-ttl`, or `noeviction` |
| Maximum clients | 10–100 |
| Idle client timeout | 0–300 seconds; zero disables idle disconnects |

The cPanel page sends typed values through a canonical broker request; the broker repeats the range and enum checks and derives the instance from the authenticated socket peer. On a running service, ORM reads the current runtime values, stages a complete broker-generated configuration file, applies all four selected values through fixed Redis/Valkey `CONFIG SET` calls, then atomically replaces the saved file. Applying all fields also restores supported in-range runtime values changed directly through the account socket. Redis and Valkey document `CONFIG SET` as a runtime configuration operation ([Redis](https://redis.io/docs/latest/commands/config-set/), [Valkey](https://valkey.io/commands/config-set/)). If ORM cannot read runtime settings, it makes no changes. If an installed version rejects a setting or saving fails, ORM attempts to restore the captured pre-request runtime values and reports an uncertain outcome if rollback fails. It does not restart the service. On a stopped or failed service, settings are saved for the next start; a failed service remains reported as failed.

Reducing the memory limit can evict cached keys immediately; increasing the limit or rolling the configuration back cannot restore those keys. ORM keeps the initial preset label separate from current settings. Database count, persistence, and the host-controlled socket, TCP, data path and backend cannot be changed in cPanel. Package resource ceilings are enforced by the root-owned broker; reseller ceilings apply to provisioning.

These are guardrails in the cPanel form and broker. The account owns its Redis-compatible process and can issue commands through its private socket, so direct runtime changes can differ from the root-owned saved configuration until the next restart. If direct changes leave a setting outside ORM's supported edit bounds, the editor fails closed; stop and start the cache to reload the broker-saved configuration before editing again. The systemd resource limit still caps the process; per-package enforcement requires a stronger tenant boundary and is not claimed here.

## Defaults and existing instances

WHM global defaults apply to newly provisioned instances. A global default update should not silently rewrite existing accounts. Existing ORM-managed settings are changed through the account's cPanel controls or by a separately confirmed admin action.

## Eviction and persistence

Explain how an eviction policy changes what happens when memory is full. Redis persistence is distinct from ORM's explicit backup feature; display those behaviors separately so operators understand latency and durability tradeoffs.
