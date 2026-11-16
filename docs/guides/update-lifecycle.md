# WHM update lifecycle

## Reference product behavior

The public reference documentation describes an in-WHM update flow that checks the current product version, applies the current release, and asks the administrator to verify that WHM and cPanel still load, accounts remain visible, provider settings remain available, and the displayed version matches the release. It also states that supported updates preserve existing Redis instances and account configuration. These are vendor claims, not guarantees for ORM.

The reference site also describes a special cleanup path for its own pre-v2.0.3 plugin and an uninstall command that can remove Redis instances and configuration. Those procedures are specific to that commercial product. Do not run them against ORM or another installation.

## ORM status

ORM has no in-panel updater, migration engine, release feed, or general release updater. `packaging/upgrade.sh` provides a narrowly scoped compatibility bridge from the identity-only v1 installation captured by [`packaging/legacy/identity-v1/install.manifest`](../../packaging/legacy/identity-v1/install.manifest). It accepts only an exact file and mode match, a matching registered WHM AppConfig file, and absent instance roots. Any changed file, unknown ORM file, symlink, registration mismatch, or existing instance root causes a refusal before mutation.

The bridge serializes install lifecycle operations, snapshots package files, prevents new broker connections while existing requests drain, updates cPanel registration through cPanel's plugin tools, atomically replaces managed files, writes a root-owned file hash manifest, and restores the prior broker enabled/active state. It rolls back file and cPanel registration changes when a step fails. It never creates or changes `/etc/orm-instances` or `/var/lib/orm-instances`. It is not a general updater for releases after this bridge; those releases still need a versioned updater and recovery path. See the [package guide](../../packaging/README.md).

cPanel documents `install_plugin` as the supported way to register a plugin and `uninstall_plugin` as the supported way to remove that registration; the ORM bridge uses both for a reversible replacement ([cPanel plugin installation guide](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins), [`install_plugin` reference](https://docs.cpanel.net/whm/scripts/the-install_plugin-script/), [cPanel plugin uninstall guide](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins/guide-to-cpanel-plugins-uninstall-plugins)).

## Required ORM update design

- Authenticate and authorize the WHM operator before checking or applying an update.
- Display the installed version, selected release, package digest/signature, compatibility result, and affected files before mutation.
- Preserve existing Redis/Valkey selection, account identity, ports, credentials, configuration, and data unless the administrator starts a separate explicit migration.
- Back up ORM-owned metadata, validate it, then apply a versioned migration with a rollback path.
- Keep service restarts and account downtime visible; do not silently restart or migrate an instance as part of a UI refresh.
- Record the actor, release, result, and recovery details without credentials in the audit log.
- Verify registration, account visibility, service health, and version after updating.

The current status is tracked in [issue #7](../../project/issues/07-validation.md) and the [ORM project plan](../../project/README.md).
