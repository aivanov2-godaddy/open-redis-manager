# Live cPanel smoke test

`tests/cpanel-live-smoke.py` checks the installed cPanel entry point on a disposable cPanel & WHM host. It uses WHM's temporary single-sign-on session, requests the ORM page, and verifies that the LiveAPI account matches the identity returned by the local broker. It performs no Redis/Valkey operation.

Run as root on a test host with exactly one cPanel account:

```sh
python3 tests/cpanel-live-smoke.py
```

On a multi-account test host, pass an explicit cPanel username:

```sh
python3 tests/cpanel-live-smoke.py --user example
```

The check requires an installed ORM cPanel entry point, an active `orm-broker.service`, valid HTTPS for the temporary session URL, and WHM API access to `create_user_session`. It reads the session URL and account name only in memory and prints only a pass/fail result. cPanel expires unused temporary sessions; the smoke test does not save credentials, tokens, hostnames, account names, page content, or session URLs.

## Current evidence

A live cPanel identity smoke passed on 2026-11-20 against the current entry point and identity classes. The test host was missing the current read-only `ApplicationDiscovery.php` dependency, so that exact file was installed before rerunning the smoke. The existing package manifest and several updater files do not match the current checkout, so this result is not a full install or upgrade validation. See [`records/2026-11-20-cpanel-identity-smoke-after-repair.md`](records/2026-11-20-cpanel-identity-smoke-after-repair.md).

Earlier evidence from three private test runs on 2026-11-16 is recorded in [`records/2026-11-16-identity-smoke.md`](records/2026-11-16-identity-smoke.md). That run also observed a Redis container managed by cPanel's Podman integration, but it did not perform Redis/Valkey operations or establish the deployed repository revision.

On 2026-11-17, the repository owner supplied a separate PHP 8.5 CLI/PhpRedis smoke result: the test account connected to its EA Podman Redis Unix socket and `PING` returned `1`. The provenance and exact scope are recorded in [`records/2026-11-17-ea-podman-phpredis-smoke.md`](records/2026-11-17-ea-podman-phpredis-smoke.md). This is a user-supplied result, not a run of the repository smoke harness.

This evidence does not verify fresh installation, cross-account denial, lifecycle controls, metrics, configuration, backups, restore, migration, recovery, uninstall, or a supported production matrix. Those remain release gates.

Other narrowly scoped live test results are recorded separately: the [managed-v1 package upgrade](records/2026-11-20-managed-v1-upgrade.md) passed on one cPanel test system, and the [Jupiter icon registration refresh](records/2026-11-20-cpanel-icon-registration.md) records the accepted flattened-path icon package and sprite regeneration. Neither run verifies the cPanel identity smoke's other scenarios or establishes host support.

See the [host compatibility and validation matrix](compatibility-matrix.md) for the remaining scenarios and candidate host combinations, and use the [validation record template](record-template.md) to capture future runs without recording private host or account details.

The test uses cPanel's documented [`create_user_session` single-sign-on flow](https://api.docs.cpanel.net/guides/guide-to-api-authentication/guide-to-api-authentication-single-sign-on).
