# Provider policy and reseller quotas

ORM keeps provider policy in `/etc/orm-provider-policy.json`, a root-owned mode `0600` file. The WHM controls are root-only. Invalid or unsafe policy files fail closed; WHM does not replace them with defaults. Changes are written atomically and recorded as fixed `orm-whm` authpriv audit events without account names, package names, logo data, support URLs, or quota values.

## Policy modes

- **Report-only** is the default for new policy files. Violations are logged and operations continue without a cPanel warning.
- **Warn** allows the operation and returns fixed warning codes that cPanel turns into generic user-facing notices. No reseller name, quota value, package name or provider setting is returned.
- **Enforce** blocks new provisions that violate package or reseller rules and blocks configuration memory changes above the package memory cap.

Version-one through version-three policy files are migrated in memory to version four. A version-one report-only setting maps to **Warn** so existing installations keep their previous user-facing warning behavior; enforcement, exposure, package, reseller, and branding settings are preserved. Saving in WHM writes the normalized version-four form. Invalid policy files fail closed in both PHP and the root-owned broker reader.

## Defaults for new instances

Root WHM can set a global memory default (8–64 MiB), an allowlisted eviction policy, a database count (1–16), and hourly metrics-history retention (7–90 days). The default package rule sets eligibility, a memory ceiling, and snapshot retention; package-specific rules can override those package values. Each new ORM-managed instance records its effective snapshot retention, database count, and history-retention value in its root-owned manifest and renders them into its generated Redis/Valkey configuration or metrics collector. Memory defaults are limited by the chosen workload preset and the effective package memory ceiling.

Changing these defaults affects future provisioning only. It does not rewrite existing Redis configuration, manifests, snapshots, or metrics history. Existing instances keep their recorded snapshot retention, database count, and history retention. Package eligibility and memory ceilings continue to govern provisioning and later memory changes. Legacy manifests keep their 16-database, three-snapshot maximum, and 30-day history behavior.

## Package rules

Package identity comes from the trusted cPanel account record. Accounts without a package-specific rule use the default rule. Each package rule controls whether new ORM instances may be created, the maximum memory setting (8–64 MiB), and snapshot retention (two or three snapshots). The two-snapshot minimum lets a selected restore point and its safety snapshot coexist during recovery. Package memory enforcement applies during provisioning and later configuration requests; package enablement gates new provisioning.

## Reseller quotas

Reseller identity comes from the trusted cPanel account `OWNER` value. Root WHM can set a maximum configured instance count and aggregate configured memory in MiB for each OWNER. A value of `0` means unlimited. Quotas gate new provisioning only; already configured accounts remain grandfathered. Configured instances count whether their service is running or stopped. The broker serializes quota check and provisioning with a private root-owned lock so concurrent requests cannot both consume the same remaining capacity.

The WHM summary contains only the OWNER name, configured instance count, active instance count, total configured memory, and quota ceilings. It reads instance details from root-owned managed-instance manifests and resolves ownership from the trusted cPanel account records. If any relevant inventory entry cannot be verified, the summary fails closed and shows unavailable rather than partial usage. cPanel receives only a fixed warning or denial, never reseller inventory or quota values.

## cPanel exposure

The root administrator can select one global exposure level. Exposure changes which page sections are rendered and does not change authorization or broker operations. A failed or invalid exposure response falls back to Simple.

| Tier | Visible cPanel features |
|---|---|
| Simple | Basic status and setup, start/stop lifecycle, endpoint details, and the PhpRedis connection helper |
| Developer | Simple plus workload presets, live and historical metrics, bounded configuration, all application helpers, and diagnostics |
| Advanced | Developer plus snapshot creation, download, and restore |

## Provider branding

Root WHM can set the cPanel product name, upload a logo, add an HTTPS support URL, choose a one-click color preset, edit four honestly labelled colors, and show or hide the product/support footer. Presets are color palettes only; a provider's product name, logo, and support URL remain their own. The WHM editor includes a live cPanel-style preview. The settings are mirrored through the account-scoped broker operation; cPanel receives display data only and no package limits, reseller usage, or provider policy values.

The four roles are primary action, link, panel background, and text. ORM, UnderHost-inspired, Redis-inspired, and Valkey-inspired palettes change those color values without replacing provider identity or logo artwork; choosing a color manually switches the selection to Custom. These are original suggested palettes, not official third-party branding assets. Foreground colors must provide at least 4.5:1 contrast against the selected panel background, and the primary action color must also contrast against white button text. Logos must be valid PNG files no larger than 32 KiB, between 16×16 and 512×256 pixels. SVG, JPEG, and other active or unsupported image formats are rejected. Product names use a bounded plain-text character set and are HTML-escaped. Support links must use HTTPS and cannot contain credentials, queries, or fragments. Invalid inputs leave the existing branding unchanged. The root-owned policy file stores the bounded base64 PNG; the broker validates it again before sending it to cPanel.

The mapping is ORM's product choice; the reference site names these tiers but does not specify exact section boundaries. Existing session, account, CSRF, and broker checks continue to apply. Hiding a section is not a new access-control boundary.

## Configure in WHM

Open **WHM → Open Redis Manager → Provider policy and new instance defaults**. Root can edit global defaults for newly created instances, the default package rule, package-specific rules, policy mode, cPanel exposure, reseller quotas, and provider branding. Quota fields accept zero as unlimited. Names must match the trusted cPanel `OWNER` value exactly.

See the [WHM policy and reseller preview](../../screenshots/whm-package-policy.png) and the [cPanel exposure tiers preview](../../screenshots/cpanel-exposure-tiers.png). Both use synthetic names and values; they are not connected to a live WHM server.

## Validation status

Schema migration, atomic root-owned storage, global-default bounds, fail-closed Perl/PHP policy validation, per-instance default snapshots, history pruning, branding input validation, contrast checks, PNG bounds, package enforcement, reseller quota checks, stopped-instance accounting, quota serialization, root-only reseller summaries, and exposure allowlisting are covered by automated tests and repository CI. Live validation on supported disposable cPanel/WHM hosts remains a release gate; see [the validation guide](../validation/cpanel-smoke.md).
