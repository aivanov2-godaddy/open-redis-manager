# Installation and compatibility plan

## Prototype

The repository currently contains a standalone PHP UI demonstration. It needs only PHP 8.1+ and a browser:

```sh
php -S 127.0.0.1:8080
```

This does not install a cPanel plugin, create a Redis service, or expose WHM controls.

## Production installation requirements (planned)

A production installer must be designed and reviewed for a supported cPanel/WHM release and OS matrix before it is published. Expected work includes:

1. Verify the operator is root and detect cPanel/WHM, operating system, package manager, PHP stack and required disk/memory headroom.
2. Detect installed Redis and Valkey packages, binaries, services and existing account instances without changing them.
3. Install the plugin files and register cPanel/WHM entry points with least privilege.
4. Create a root-owned service boundary for privileged operations; account UI requests must never call shell commands directly.
5. Persist account metadata and migrations with a tested backup and rollback path.
6. Validate plugin visibility, account isolation, service health and update compatibility before reporting success.

The repo now contains cPanel and WHM entry points, a manual development installer, explicit WHM backend selection, root-only report-only/enforce package policy, and account-scoped provision/status/start/stop/live metrics through a root broker and systemd template. cPanel provisioning accepts a fixed workload preset, with the memory value selected and capped by the broker and optional per-package ceiling. The cPanel page obtains the authenticated identity from LiveAPI, then the broker derives the target and package from trusted account metadata. The lifecycle remains unvalidated on a supported disposable cPanel host matrix. Use only on a disposable cPanel & WHM server.

## Backend selection plan

The implementation will have a Redis-compatible backend interface for discovery, lifecycle, configuration, metrics, snapshots and migration. New installation defaults may use host capabilities and administrator policy. Upgrades preserve the existing backend and account data. Redis-to-Valkey migration is always per account, snapshot-backed and explicitly initiated.

## Runtime compatibility checklist

- Redis or Valkey server package/service supported on the target OS.
- Compatible PHP extension/client library enabled for each PHP runtime that needs it.
- cPanel user and WHM administrator entry points registered under the supported themes/API surface.
- CloudLinux PHP Selector and CageFS behavior documented and validated when present.
- Resource ceilings account for total system memory, not only per-instance values.
- Uninstall removes project-owned files and registrations while preserving user data unless the administrator explicitly chooses otherwise.
