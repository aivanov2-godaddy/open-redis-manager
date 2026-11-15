# WHM update lifecycle

## Reference product behavior

The public reference documentation describes an in-WHM update flow that checks the current product version, applies the current release, and asks the administrator to verify that WHM and cPanel still load, accounts remain visible, provider settings remain available, and the displayed version matches the release. It also states that supported updates preserve existing Redis instances and account configuration. These are vendor claims, not guarantees for ORM.

The reference site also describes a special cleanup path for its own pre-v2.0.3 plugin and an uninstall command that can remove Redis instances and configuration. Those procedures are specific to that commercial product. Do not run them against ORM or another installation.

## ORM status

ORM has no in-panel updater, migration engine, release feed, or supported upgrade path yet. The development installer in [`packaging/`](../../packaging/README.md) is not an updater. Never use it to overwrite an existing installation: it deliberately refuses existing target files.

## Required ORM update design

- Authenticate and authorize the WHM operator before checking or applying an update.
- Display the installed version, selected release, package digest/signature, compatibility result, and affected files before mutation.
- Preserve existing Redis/Valkey selection, account identity, ports, credentials, configuration, and data unless the administrator starts a separate explicit migration.
- Back up ORM-owned metadata, validate it, then apply a versioned migration with a rollback path.
- Keep service restarts and account downtime visible; do not silently restart or migrate an instance as part of a UI refresh.
- Record the actor, release, result, and recovery details without credentials in the audit log.
- Verify registration, account visibility, service health, and version after updating.

The current status is tracked in [issue #7](../../project/issues/07-validation.md) and the [ORM project plan](../../project/README.md).
