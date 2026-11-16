# Provider package policy

ORM supports a root-only WHM policy for package-level provisioning and resource limits. The initial mode is **report-only**. In that mode, policy violations are recorded and shown to the cPanel user after provisioning or a memory change, but they do not block the request. Select **Enforce** in WHM to apply the configured rules.

## Package rules

The policy matches the exact cPanel package name from the trusted account record. Accounts without a package-specific rule use the default rule. Each rule controls:

- Whether new ORM instances may be provisioned for that package.
- The maximum memory setting, from 8 to 64 MiB.
- Snapshot retention, from two to three snapshots. The two-snapshot minimum allows a selected restore point and its safety snapshot to coexist during recovery.

The broker checks the policy independently of the WHM or cPanel form. Enforced memory ceilings apply during provisioning and later configuration requests. A policy change never rewrites existing instance configuration or stops a running service. A new snapshot is validated before older snapshots are removed to meet a reduced retention limit.

## Configure in WHM

Open **WHM → Open Redis Manager → Package resource policy**. Root can change the default rule, add or remove package-specific rules, and select report-only or enforce mode. Changes are written atomically to `/etc/orm-provider-policy.json`, which must remain root-owned and mode `0600`. The WHM page rejects unsafe or malformed policy files and does not replace them with defaults.

See the [static WHM UI preview](../../screenshots/whm-package-policy.png) for the layout; its package names and values are synthetic.

The policy update event is written to the cPanel server error log without package names, account names, or policy values. cPanel users see only a generic denial or a fixed report-only warning; provider policy details remain in WHM.

Package rules do not set reseller quotas, provider branding, or Simple/Developer/Advanced exposure. Reseller quotas and exposure levels remain planned work under [issue #6](https://github.com/aivanov2-godaddy/open-redis-manager/issues/6).

## Validation status

The provider policy parser, root-owned file store, package metadata resolution, report-only behavior, enforcement, and account-facing response validation are covered by automated tests. Live validation on the documented supported cPanel/WHM matrix remains a separate release gate; see [the validation guide](../validation/cpanel-smoke.md).
