# Provider policy and reseller quotas

ORM keeps provider policy in `/etc/orm-provider-policy.json`, a root-owned mode `0600` file. The WHM controls are root-only. Invalid or unsafe policy files fail closed; WHM does not replace them with defaults. Changes are written atomically and the page records the change in the server log without logging account names or quota values.

## Policy modes

- **Report-only** is the default for new policy files. Violations are logged and operations continue without a cPanel warning.
- **Warn** allows the operation and returns fixed warning codes that cPanel turns into generic user-facing notices. No reseller name, quota value, package name or provider setting is returned.
- **Enforce** blocks new provisions that violate package or reseller rules and blocks configuration memory changes above the package memory cap.

Version-one policy files are migrated in memory to version two. A version-one report-only setting maps to **Warn** so existing installations keep their previous user-facing warning behavior. Saving in WHM writes the normalized version-two form. Policy changes never rewrite, stop, or remove existing instances.

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

The mapping is ORM's product choice; the reference site names these tiers but does not specify exact section boundaries. Existing session, account, CSRF, and broker checks continue to apply. Hiding a section is not a new access-control boundary.

## Configure in WHM

Open **WHM → Open Redis Manager → Package resource policy**. Root can edit the default rule, save or remove package-specific rules, choose report-only/warn/enforce, choose the cPanel exposure tier, and save or remove reseller quotas. Quota fields accept zero as unlimited. Names must match the trusted cPanel `OWNER` value exactly.

See the [WHM policy and reseller preview](../../screenshots/whm-package-policy.png) and the [cPanel exposure tiers preview](../../screenshots/cpanel-exposure-tiers.png). Both use synthetic names and values; they are not connected to a live WHM server.

## Validation status

Schema migration, atomic root-owned storage, package enforcement, reseller quota checks, stopped-instance accounting, quota serialization, root-only reseller summaries, cPanel response validation, and exposure allowlisting are covered by automated tests and repository CI. Live validation on supported disposable cPanel/WHM hosts remains a release gate; see [the validation guide](../validation/cpanel-smoke.md).
