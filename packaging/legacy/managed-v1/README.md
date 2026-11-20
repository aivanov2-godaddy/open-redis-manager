# Managed ORM v1 upgrade baseline

This directory pins the exact, fully managed v1 package state represented by the repository snapshot at commit `c123b936d4857c418fd9ed038c501673177a2340`. It is a compatibility fixture for that historical install, not a general v1 migration rule.

- `install.manifest` is the exact original 28-row manifest.
- `files.map` records each managed file's original target, mode, and SHA-256 digest. The upgrader cross-checks its keys, source paths, target paths, and modes against the current package map before accepting a baseline.
- `fixtures.tar.gz` contains exactly those 28 old package files under `files/<key>` for deterministic tests.
- `cpanel/` preserves the original cPanel registration JSON and icon artwork so a failed upgrade can restore the prior registration.

The upgrader accepts this baseline only when the manifest bytes and metadata, every recorded file, the complete managed file and directory inventory, the exact cPanel entry file set, and any existing root-owned instance roots all match the expected state. Drift is refused before service or registration changes. Keep the fixture immutable; add a separately reviewed baseline if a different historical install must be supported.
