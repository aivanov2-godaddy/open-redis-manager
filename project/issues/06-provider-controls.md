# Add package, reseller, policy and branding controls

## Goal
Give hosting providers bounded, reversible controls over new Redis provisioning.

## Acceptance criteria
- Report-only is the initial policy mode.
- Package policy defines enablement and explicit resource/retention ceilings.
- Reseller quotas gate new provisioning and do not silently rewrite existing accounts.
- Simple/Developer/Advanced exposure changes visibility but does not grant new privilege.
- Branding validates logo/color input and maintains readable contrast.
- Changes are audited and reflected in cPanel without exposing provider-only settings.

## Progress

- The current implementation adds root-only WHM package rules for provisioning availability, memory/client/database ceilings, and snapshot retention. Package identity comes from trusted account records. New instances receive capped client/database settings; enforce mode blocks over-cap memory/client changes, while a previously higher client value can remain unchanged or decrease. Report-only, warn, and enforce behavior is explicit and policy changes do not rewrite existing instances. cPanel receives only fixed warnings or denials, not provider limits.
- Reseller quotas count configured instances and aggregate memory, including stopped instances, and gate new provisioning only. Simple/Developer/Advanced exposure changes rendered controls without changing broker authorization. Live validation on a supported disposable cPanel/WHM matrix remains a release gate.
- Provider branding covers product name, structurally validated PNG logo, HTTPS support URL, four labelled theme colors, ORM/UnderHost/Redis/Valkey palettes, footer visibility, and a live WHM preview. The broker mirrors only these display settings to cPanel; disposable-host validation remains open.
