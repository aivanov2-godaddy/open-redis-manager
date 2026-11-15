# Read-only backend discovery

ORM includes read-only discovery for Redis and Valkey. It is available as a CLI command and through the authenticated, root-ACL-protected WHM entrypoint. The unauthenticated prototype `index.php` does not call host discovery.

## Run it

On a Linux host with PHP CLI:

```sh
php bin/orm backend:discover --json
```

The command reports whether the host platform is supported, common Redis/Valkey server and client binaries, a parsed server version when available, and systemd unit state when it can be determined. The JSON includes a schema version and limitations.

On other platforms, it prints an `unsupported-platform` report and exits with status 2. This lets local developers inspect the report shape without suggesting that Windows is a valid cPanel host.

## Safety boundary

- The standalone command is CLI-only. The WHM route calls the same class only after AppConfig and the entrypoint verify root-level WHM ACL access.
- Linux only for host discovery.
- Checks fixed common binary paths; it does not search `PATH`, accept paths or service names from input, or read Redis configuration and credentials.
- Version and systemd state checks use fixed argument arrays, without a shell. Each subprocess has a short timeout and bounded output.
- It does not install packages, start/stop/reload services, change files, connect to Redis, or inspect account metadata.
- Account counts remain `null`; finding a binary or unit does not mean ORM owns or manages any Redis instances.

## Known limits

Linux execution, systemd behavior, package-specific paths, permissions, cPanel integration, and installed Redis/Valkey hosts have not yet been validated in this Windows development environment. Non-systemd services and binaries outside the known paths are reported as unknown/not detected; that result does not prove the backend is absent. The prototype WHM Backends screen still uses demonstration data. The separate authenticated WHM entrypoint displays discovery results but is not packaged or installed by an installer.

Next work tracked by [issue #2](https://github.com/aivanov2-godaddy/open-redis-manager/issues/2) is to validate supported package layouts on disposable cPanel hosts and then connect trusted ORM account metadata to this discovery view.
