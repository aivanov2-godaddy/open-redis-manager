# Reference website content map

This is an original-language index of the public marketing page, so the main audience, claims, visual sections and use cases remain traceable without copying vendor page text. See [reference notes](../source-notes.md) for links and limitations.

## Product promise and audience

The reference presents Redis and Valkey as cPanel/WHM-managed cache services. It positions the product for individual site owners, agencies/developers, hosting companies and resellers. The claimed benefits are lower latency, fewer repeated database reads, and more responsive applications during traffic spikes. ORM's documentation should describe these as workload-dependent outcomes rather than performance guarantees.

## Benefit and request-flow sections

- **Keep hot data in memory:** reduce repeated backend work for data that applications choose to cache.
- **Reduce database pressure:** repeated reads can be served from cache when the application is integrated correctly.
- **Stay responsive under load:** reuse cached results where the application permits it.
- **Request sequence:** incoming request → application checks cache → cache hit returns quickly, or cache miss reads the source and warms the cache → later requests may reuse it.

## Application use cases

| App/workload | Typical Redis role described by the site |
|---|---|
| WordPress and WooCommerce | Persistent object cache; possible reduction in repeated database reads. |
| Laravel and modern PHP | Application cache, sessions, queues and rate limiting. |
| Magento | Cache/session workload for catalog and storefront operations. |
| Custom PHP and APIs | Cache repeated computation, API responses or sessions. |
| Forums and membership systems | Session and repeated lookup acceleration. |
| CRM and administration tools | Reuse dashboard data and customer record lookups. |

## Control-panel story

- **cPanel user surface:** one account, lifecycle, endpoint and credential, current metrics, presets, configuration, backups/restore, application setup and diagnostics.
- **WHM operator surface:** fleet dashboard, account filtering/actions, Redis command console, backups, recovery, backend selection, defaults, security, package controls and branding.
- **Provider story:** make Redis-compatible service access part of a package, scope reseller quotas, expose a simpler or more advanced user UI, and brand the experience.
- **Compatibility story:** support Redis and Valkey; automatically choose a backend for new systems only when supported; preserve existing Redis accounts by default.

## Visual content on the site

The public page describes a cPanel dashboard, monitoring view and configuration/backups screen, then WHM screenshots for the server dashboard, account table, CLI, backups, recovery, global configuration, security, package policy and branding. ORM uses its own original UI, icon drawings and screenshots. See [screenshot map](screenshot-map.md).

## Roadmap themes communicated on the site

The page separates features presented as currently available from security/licensing work in the next release and longer-term themes such as APIs/webhooks, deeper observability, workers, cross-server transfer, clustering and another control panel. ORM tracks these independently in [the project plan](../../project/README.md); reference roadmap items are not commitments for ORM.

## Site sections outside the feature UI

The page also includes a version and release status, license pricing, FAQs, application examples, documentation links, upgrade guidance, and support/product links. The [FAQ reference summary](../faq-reference.md) and [roadmap reference](../roadmap-reference.md) capture those areas in separate files. Purchasing and licensing are vendor-specific and are not part of ORM's open-source core.
