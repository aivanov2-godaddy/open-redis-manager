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
