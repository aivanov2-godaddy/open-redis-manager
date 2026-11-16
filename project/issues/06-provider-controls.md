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

- The current implementation adds root-only WHM package rules for provisioning availability, memory ceilings, and snapshot retention. The broker reads the cPanel account plan from its trusted account record; policy defaults to report-only and explicit enforcement does not rewrite existing instances. Fixed policy warnings/denials are reflected in cPanel without returning rule details.
- Reseller quotas and Simple/Developer/Advanced exposure levels remain open acceptance criteria.
