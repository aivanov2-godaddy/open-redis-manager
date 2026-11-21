# Reference site: upgrade page

**Source:** [cpanelredismanager.com/upgrade.php](https://cpanelredismanager.com/upgrade.php)
**Observed:** 2026-11-21; the page displayed v2.6.11. See the [REA evidence ledger](../rea-evidence.md#read-only-recheck-on-2026-11-21).

## Update model claimed by the source

The page directs administrators to update through WHM and describes a release-aware, in-panel workflow. It says normal use does not require a public low-level upgrade command. The page claims supported updates preserve existing Redis instances, account configuration, and operational state while refreshing the cPanel and WHM surfaces.

The page asks an administrator to confirm that WHM still loads, accounts remain manageable, branding and package controls remain available, and the displayed version matches the current public release. It identifies v2.6.11 as current at capture time.

These are vendor statements, not observed update execution. The REA capture opened only the public page; no package was downloaded, installed, or updated.

## ORM update workflow

ORM's current approach is documented in the [update lifecycle guide](../guides/update-lifecycle.md): releases are staged and signed out of band, then reviewed through a root-only WHM preview and explicit apply flow. ORM does not fetch or install vendor updates. Its exact behavior, compatibility limits, and validation status remain separate from the reference site's claims.
