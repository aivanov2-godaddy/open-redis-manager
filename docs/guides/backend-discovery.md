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
- The host-discovery command does not inspect account metadata, so its `managed_account_count` remains `null`. In WHM, the separate root-only fleet summary counts accounts only after cPanel identity and ORM manifest validation. It returns Redis/Valkey aggregates without account names; older brokers may leave those counts unavailable. These counts exclude unmanaged services and cPanel Podman containers.

## Known limits

Linux execution, systemd behavior, package-specific paths, permissions, cPanel integration, and installed Redis/Valkey hosts have not yet been validated in this Windows development environment. Non-systemd services and binaries outside the known paths are reported as unknown/not detected; that result does not prove the backend is absent. The prototype WHM Backends screen still uses demonstration data. The separate authenticated WHM entrypoint displays discovery results but is not packaged or installed by an installer.

The WHM backend table displays managed ORM account counts after root loads the verified fleet summary. Host discovery remains read-only and separate from the account inventory; the count does not imply ownership of services discovered outside ORM.

Next work tracked by [issue #2](https://github.com/aivanov2-godaddy/open-redis-manager/issues/2) is to validate supported package layouts on disposable cPanel hosts and complete migration-readiness reporting.
