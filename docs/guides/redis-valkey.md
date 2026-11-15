# Redis and Valkey backend behavior

## Compatibility model

Treat Redis and Valkey as distinct backend implementations behind a common management interface. Discover server binaries, client CLI, service units and versions independently; report what the host actually provides.

## New installs and upgrades

An administrator may configure Auto-detect, Redis or Valkey for new provisioning. OS/package detection may inform an automatic choice, but the supported matrix must come from ORM validation. Existing installations retain their current backend during upgrade unless the administrator deliberately migrates them.

## Explicit migration

Migration operates on one chosen account: check the target service and configuration, take and verify a snapshot, stop/switch/start as necessary, check health and connectivity, then roll back to the old backend if a required check fails. Show expected interruption and rollback limits before confirmation. A readiness diagnostic alone must never mutate an account.

## Service isolation

Each account instance must have a private identity, bounded resource configuration and private endpoint. Backend commands use fixed paths and server-derived metadata. No customer-supplied shell fragments are allowed.
