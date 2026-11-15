# cPanel and WHM entry-point scaffold

This folder contains the cPanel and WHM registration files, authenticated UI entry points, and the first manual installer lifecycle for Open Redis Manager:

- `cpanel/install.json` registers one feature group and one Jupiter interface link.
- `cpanel/files/orm/index.live.php` uses cPanel's LiveAPI PHP class and its session header/footer, and displays the validated current account username from LiveAPI.
- `whm/open_redis_manager.conf` registers a root-level WHM AppConfig entry guarded by `acls=all`.
- `whm/cgi/addon_open_redis_manager.php` renders the WHM interface and repeats an ACL check before showing it.
- `cpanel/icons/` and `whm/icons/` hold original ORM registration artwork.
- `install.sh` installs the cPanel link and WHM discovery page from this checkout.
- `uninstall.sh` unregisters the cPanel link and WHM AppConfig entry, then removes only exact files whose contents match this checkout.
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

These scripts target cPanel's Jupiter theme. The installer checks for Linux, root, the cPanel interface files, and the documented cPanel and WHM registration utilities. It refuses file collisions and an existing WHM AppConfig registration. It does not install Redis or Valkey, start/stop services, inspect or change service configuration, create account instances, or alter Redis data. Uninstall compares each installed file with the matching file in the checkout and stops if it differs. Keep the matching source revision available for uninstall.

The scripts have not been run on a cPanel host. No supported cPanel/WHM version or OS matrix has been established, and upgrades, backup/restore of ORM-owned files, reseller authorization, account isolation, and feature implementation remain open work. Treat this as a development installer for a disposable host, not a production release.

## Current limits

These are authenticated entry points, not a complete Redis control plane. The WHM page requires root-level access and checks the authenticated `REMOTE_USER` against `/var/cpanel/resellers`; missing identity, unreadable ACL data, malformed names, oversized ACL data, and unknown permissions fail closed. The ACL file path is fixed. Once authorized, WHM calls the read-only backend discovery class and displays binary/version/systemd observations; it does not inspect account metadata or modify the host. The cPanel page reads only the authenticated username from LiveAPI UAPI; it does not access Redis instance data or perform service operations. The account isolation adapter remains unimplemented.

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
