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

A third live cPanel identity smoke run passed on 2026-11-16. The sanitized environment and scenario results are in [`records/2026-11-16-identity-smoke.md`](records/2026-11-16-identity-smoke.md). The run verified the installed cPanel page's LiveAPI identity check while the broker was active and observed a Redis container managed by cPanel's Podman integration. It did not perform Redis/Valkey operations, and it did not establish which repository revision is installed.

This evidence does not verify fresh installation, cross-account denial, lifecycle controls, metrics, configuration, backups, restore, migration, recovery, uninstall, or a supported production matrix. Those remain release gates.

See the [host compatibility and validation matrix](compatibility-matrix.md) for the remaining scenarios and candidate host combinations, and use the [validation record template](record-template.md) to capture future runs without recording private host or account details.

The test uses cPanel's documented [`create_user_session` single-sign-on flow](https://api.docs.cpanel.net/guides/guide-to-api-authentication/guide-to-api-authentication-single-sign-on).
