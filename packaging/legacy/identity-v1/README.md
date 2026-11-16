# Identity-only v1 upgrade baseline

This fixture records the files installed by the ORM identity-only package at commit [`acbfce9`](https://github.com/aivanov2-godaddy/open-redis-manager/commit/acbfce94d8644dd899096af326c0a58ffaa004de). `install.manifest` stores the expected SHA-256 and mode for each deployed file. The AppConfig fixture includes the `name=open_redis_manager` field that cPanel's `register_appconfig` utility appends to the packaged settings. `cpanel/` contains the matching plugin registration archive inputs so the upgrade can restore that registration if the replacement fails.

The upgrader accepts only this exact baseline. The matching installed-file fixtures under [`tests/fixtures/orm-identity-v1-install`](../../../tests/fixtures/orm-identity-v1-install) exercise the integrity and rollback checks. No server-specific files or configuration are part of this fixture.
