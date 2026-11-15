# Configuration and workload presets

## Presets currently available during setup

The feature inventory includes five starting profiles:

- **WordPress:** object-cache workload.
- **Laravel:** application cache and session/queue usage.
- **Magento:** storefront cache workload.
- **Session cache:** user session storage.
- **Generic:** a neutral baseline for custom applications.

The cPanel initialization form offers all five profiles. The broker accepts only these preset IDs and chooses the memory limit server-side:

| Preset | Initial memory limit |
|---|---:|
| WordPress | 48 MiB |
| Laravel | 32 MiB |
| Magento | 64 MiB |
| Session cache | 32 MiB |
| Generic | 64 MiB |

All profiles currently use `allkeys-lru`, 16 logical databases, a 100-client ceiling, no client idle timeout, and persistence disabled. The current hard cap is 64 MiB. Package and reseller ceilings are not implemented yet. The selected profile is stored in the root-owned instance manifest; version 1 manifests continue to read as Generic. Presets are currently selected during initial provisioning; changing a profile or individual settings on an existing service is not available yet.

The preview lists the effective memory limit before instance creation. The profile never accepts raw configuration values from the browser.

## Advanced values

The reference docs list memory cap, eviction policy, database count, client timeout, max clients and persistence among tunable values. ORM should validate numeric bounds and enum values server-side. Advanced options are visible only when provider exposure allows them, while server-side package bounds always apply.

## Defaults and existing instances

WHM global defaults apply to newly provisioned instances. A global default update should not silently rewrite existing accounts. Existing changes are made through their own account controls or by a separately confirmed admin action.

## Eviction and persistence

Explain how an eviction policy changes what happens when memory is full. Redis persistence is distinct from ORM's explicit backup feature; display those behaviors separately so operators understand latency and durability tradeoffs.
