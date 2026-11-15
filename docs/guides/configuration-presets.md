# Configuration and workload presets

## Presets

The feature inventory includes five starting profiles:

- **WordPress:** object-cache workload.
- **Laravel:** application cache and session/queue usage.
- **Magento:** storefront cache workload.
- **Session cache:** user session storage.
- **Generic:** a neutral baseline for custom applications.

Presets should set safe initial values rather than override a provider's maximums. Before saving, show which values will change and the effective limit for the account's package.

## Advanced values

The reference docs list memory cap, eviction policy, database count, client timeout, max clients and persistence among tunable values. ORM should validate numeric bounds and enum values server-side. Advanced options are visible only when provider exposure allows them, while server-side package bounds always apply.

## Defaults and existing instances

WHM global defaults apply to newly provisioned instances. A global default update should not silently rewrite existing accounts. Existing changes are made through their own account controls or by a separately confirmed admin action.

## Eviction and persistence

Explain how an eviction policy changes what happens when memory is full. Redis persistence is distinct from ORM's explicit backup feature; display those behaviors separately so operators understand latency and durability tradeoffs.
