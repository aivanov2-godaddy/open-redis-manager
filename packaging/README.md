# cPanel and WHM entry-point scaffold

This folder contains the first registration and authenticated UI entry-point scaffold for Open Redis Manager:

- `cpanel/install.json` registers one feature group and one Jupiter interface link.
- `cpanel/files/orm/index.live.php` uses cPanel's LiveAPI PHP class and its session header/footer.
- `whm/open_redis_manager.conf` registers a root-level WHM AppConfig entry guarded by `acls=all`.
- `whm/cgi/addon_open_redis_manager.php` renders the WHM interface and repeats an ACL check before showing it.
- `cpanel/icons/` and `whm/icons/` hold original ORM registration artwork.

## Current limits

These are authenticated entry points, not an installer or a complete Redis control plane. The WHM page requires root-level access and checks the authenticated `REMOTE_USER` against `/var/cpanel/resellers`; missing identity, unreadable ACL data, malformed names, oversized ACL data, and unknown permissions fail closed. The ACL file path is fixed. Once authorized, WHM calls the read-only backend discovery class and displays binary/version/systemd observations; it does not inspect account metadata or modify the host. The cPanel page remains a LiveAPI shell and does not access account data yet.

The cPanel `install.json` follows cPanel's documented groups/features model and points to a `.live.php` LiveAPI interface. WHM uses AppConfig with an explicit `all` ACL. The repository does not yet include an install/upgrade/uninstall script because it must be tested against a disposable supported cPanel server before choosing copy locations, permissions, compatibility checks, and rollback behavior. Do not install these files on a production server.

## Official references

- [cPanel plugins: registration and `install.json`](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins/guide-to-cpanel-plugins-add-plugins)
- [cPanel LiveAPI PHP interface](https://api.docs.cpanel.net/guides/quickstart-development-guide/tutorial-create-a-new-cpanel-interface-in-php)
- [WHM AppConfig configuration](https://api.docs.cpanel.net/guides/guide-to-whm-plugins/guide-to-whm-plugins-appconfig-configuration-file)
- [WHM ACL checks](https://api.docs.cpanel.net/guides/guide-to-whm-plugins/guide-to-whm-plugins-access-control-lists)
- [WHM PHP interface](https://api.docs.cpanel.net/guides/quickstart-development-guide/tutorial-create-a-new-whm-interface-in-php)
