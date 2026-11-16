# cPanel and WHM entry-point scaffold

This folder contains the cPanel and WHM registration files, authenticated UI entry points, and the first manual installer lifecycle for Open Redis Manager:

- `cpanel/install.json` registers one feature group and one Jupiter interface link.
- `cpanel/files/orm/index.live.php` uses cPanel's LiveAPI PHP class and its session header/footer, compares the LiveAPI username with the local broker identity, and shows only that account's private socket path and PHP, Node.js and Python client examples.
- [`../src/Orm/Cpanel/DiagnosticReport.php`](../src/Orm/Cpanel/DiagnosticReport.php) builds the cPanel support preview/download from fixed, validated fields; the installer deploys it alongside the other account-facing PHP helpers.
- `systemd/orm-broker.service` runs the broker as root. Its fixed local protocol exposes identity, per-account instance status/provision/start/stop, a UID-0-only paginated fleet inventory, and a UID-0-only control request with a validated cPanel account name plus one of three fixed lifecycle actions. It accepts no command, path, unit name, backend or arbitrary configuration values.
- `systemd/orm-instance@.service` runs each Redis-compatible process as its cPanel account, with an account-private Unix socket, TCP disabled, bounded resources, and access only to that account's data directory.
- `systemd/orm-metrics-collect@.timer` schedules hourly history collection while the matching instance runs; its oneshot service executes the fixed Unix-socket collector as that cPanel account.
- `src/Orm/Broker/InstanceManager.pm` verifies root-owned metadata and derives service/data paths only from the authenticated account mapping.
- `whm/open_redis_manager.conf` registers a root-level WHM AppConfig entry guarded by `acls=all`.
- `whm/cgi/addon_open_redis_manager.php` renders the WHM interface and repeats an ACL check before showing it.
- `cpanel/icons/` and `whm/icons/` hold original ORM registration artwork.
- `install.sh` installs the cPanel link and WHM discovery page from this checkout.
- `upgrade.sh` is a guarded compatibility bridge for the exact identity-only install manifest in `legacy/identity-v1/`. It refuses unknown or modified files and any existing instance roots, drains active broker requests, prepares only secure empty instance roots required by the broker sandbox, reapplies cPanel registration through `install_plugin` without first removing its existing feature IDs, rolls back package files and registration on failure, and preserves the broker's enabled/active state. It removes transaction-created roots on rollback only when they remain unchanged and empty, and retains recovery files if rollback fails. This is not a general updater for later releases.
- `uninstall.sh` unregisters the cPanel link and WHM AppConfig entry, then removes only exact files whose contents match this checkout. A root-owned install manifest verifies deployed file hashes and modes first.
- `lib.sh` contains shared fixed paths, platform checks, and cPanel package assembly.

## Install and uninstall

On a disposable cPanel & WHM server, from the extracted repository root, run as root:

```sh
bash packaging/install.sh
```

To remove it using the same repository revision:

```sh
bash packaging/uninstall.sh
```

The one-time upgrade bridge applies only to the committed identity-only v1 baseline and requires both ORM instance roots to be absent before it starts. It creates the root-owned, mode-0711 metadata and data directories needed by the hardened broker; they contain no instance records or data. On failure it removes only those transaction-created directories that are unchanged and empty. It never installs, migrates, stops, or deletes Redis/Valkey data. Review [`../docs/guides/update-lifecycle.md`](../docs/guides/update-lifecycle.md) before using it.

These scripts target cPanel's Jupiter theme. The installer checks for Linux, root, Perl, systemd, the cPanel interface files, and the documented cPanel and WHM registration utilities. It refuses file collisions and an existing WHM AppConfig registration. It installs the broker and a per-account systemd template; the broker maps the connecting Linux UID to a safe, root-owned cPanel account record and never accepts account names from the request. It does not install Redis or Valkey packages. A root WHM administrator selects an already-installed backend, and cPanel users can initialize, inspect, start, or stop their own ORM instance. Uninstall compares installed files with this checkout and refuses to continue while any instance entry remains. Keep the matching source revision available for uninstall.

Linux CI exercises fresh-install success and registration-failure rollback against an isolated mock cPanel filesystem and stubbed cPanel/systemd utilities. This does not validate a live install. The install/uninstall scripts and lifecycle manager still require disposable cPanel lifecycle validation. The previous live smoke verified the PHP process UID and authenticated LiveAPI identity, but did not provision or start Redis/Valkey. No supported cPanel/WHM version or OS matrix has been established; upgrades, credentials, reseller authorization, and broader WHM controls remain open. Treat this as a development installer for a disposable host, not a production release.

## Current limits

The WHM page checks `REMOTE_USER` against cPanel's reseller ACL before displaying backend discovery or the root-only fleet view, and only root may change the selected backend policy. The policy is root-owned and affects new instances only. The cPanel page compares its LiveAPI username to the broker's kernel-derived peer identity. The broker resolves account operations from `SO_PEERCRED`; its fleet listing requires peer UID 0. Redis TCP is disabled and each socket is private to its account. cPanel can edit bounded memory, eviction, client and timeout settings; the account can also alter its own runtime through its socket, so these are not package-level enforcement. Explicit per-account RDB backups are stored under the root-controlled ORM data root, remain readable by that account, and are preserved by the uninstall guard. cPanel restore validates the selected snapshot, creates a safety copy, replaces only the account's RDB, verifies service startup, and attempts rollback on startup failure. Hourly metrics history runs as the matching cPanel account and is stored as root-owned `0600` metadata. AUTH secret management is not implemented. A root-only, single-account Redis-to-Valkey migration is implemented with version guards, a safety snapshot, verification and attempted rollback, but it has not passed disposable-host validation. Treat ORM as a development installer, not a production release.

The cPanel `install.json` follows cPanel's documented groups/features model and points to a `.live.php` LiveAPI interface. WHM uses AppConfig with an explicit `all` ACL. The manual scripts in this folder now install the cPanel entry with `install_plugin`, place the interface/code/icon files in fixed documented locations, and register WHM through AppConfig. Uninstall uses `uninstall_plugin` and `unregister_appconfig` and only removes exact matching ORM files. The lifecycle has not been exercised on an actual cPanel server; do not use it on a production server.

## Official references

- [cPanel plugins: registration and `install.json`](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins/guide-to-cpanel-plugins-add-plugins)
- [cPanel plugin install and file placement](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins)
- [cPanel plugin uninstall](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins/guide-to-cpanel-plugins-uninstall-plugins)
- [cPanel LiveAPI PHP interface](https://api.docs.cpanel.net/guides/quickstart-development-guide/tutorial-create-a-new-cpanel-interface-in-php)
- [WHM AppConfig configuration](https://api.docs.cpanel.net/guides/guide-to-whm-plugins/guide-to-whm-plugins-appconfig-configuration-file)
- [WHM ACL checks](https://api.docs.cpanel.net/guides/guide-to-whm-plugins/guide-to-whm-plugins-access-control-lists)
- [WHM PHP interface](https://api.docs.cpanel.net/guides/quickstart-development-guide/tutorial-create-a-new-whm-interface-in-php)
- [WHM plugin installation scripts](https://api.docs.cpanel.net/guides/guide-to-whm-plugins/guide-to-whm-plugins-installation-scripts)
- [WHM plugin uninstall](https://api.docs.cpanel.net/guides/guide-to-whm-plugins/guide-to-whm-plugins-uninstall-plugins)
