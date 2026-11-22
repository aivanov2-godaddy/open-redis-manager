# Populated-data uninstall guard live validation

**Date:** 2026-11-22
**Product version:** ORM `0.1.0-rc.13`
**Host:** one disposable cPanel & WHM `138.0` test host
**Source:** `976c9f8d55468ebc73df47d125cb357ce72757d4`

## Scope and preconditions

The source archive transferred to the host matched the local archive SHA-256. The live harness verified the installed package version and package-file integrity, WHM registration, and account-create hook before mutation. It found exactly one registered ORM-managed test instance, verified that its service was inactive, and verified the owner and private permissions of its data directory.

## Results

- The exact-source installer took its idempotent path.
- The exact-source uninstaller refused because managed instance files existed.
- Before and after snapshots matched for the ORM metadata and data trees, registration/hook state, and ORM service/timer states.
- The harness removed only its uniquely named, mode-`0600` synthetic sentinel and verified the original filesystem snapshot was restored.
- No Redis/Valkey service was started or stopped and no EA Podman command or state was changed.

## Limits

This verifies preservation of filesystem entries and package/runtime registration when uninstall is refused. The sentinel was synthetic; this is not a Redis keyspace or real application-data persistence test. It covers one disposable host and does not establish ORM production support.
