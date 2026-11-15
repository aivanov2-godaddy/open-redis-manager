# Read-only backend discovery

ORM now includes a CLI-only first implementation slice for Redis and Valkey discovery. It is separate from the prototype web UI because that UI does not yet authenticate users or enforce cPanel/WHM ACLs.

## Run it

On a Linux host with PHP CLI:

```sh
php bin/orm backend:discover --json
```

The command reports whether the host platform is supported, common Redis/Valkey server and client binaries, a parsed server version when available, and systemd unit state when it can be determined. The JSON includes a schema version and limitations.

On other platforms, it prints an `unsupported-platform` report and exits with status 2. This lets local developers inspect the report shape without suggesting that Windows is a valid cPanel host.

## Safety boundary

- CLI only; the command is not called from `index.php` or an HTTP route.
- Linux only for host discovery.
- Checks fixed common binary paths; it does not search `PATH`, accept paths or service names from input, or read Redis configuration and credentials.
- Version and systemd state checks use fixed argument arrays, without a shell. Each subprocess has a short timeout and bounded output.
- It does not install packages, start/stop/reload services, change files, connect to Redis, or inspect account metadata.
- Account counts remain `null`; finding a binary or unit does not mean ORM owns or manages any Redis instances.

## Known limits

Linux execution, systemd behavior, package-specific paths, permissions, cPanel integration, and installed Redis/Valkey hosts have not yet been validated in this Windows development environment. Non-systemd services and binaries outside the known paths are reported as unknown/not detected; that result does not prove the backend is absent. The WHM Backends screen still uses demonstration data until authenticated plugin entry points exist.

Next work tracked by [issue #2](https://github.com/aivanov2-godaddy/open-redis-manager/issues/2) is to validate supported package layouts on disposable cPanel hosts and then wire the discovery report through an authenticated WHM service boundary.
