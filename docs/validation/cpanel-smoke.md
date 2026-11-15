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

A live cPanel test passed: the root-run broker was active, the cPanel account UID could verify through the local socket, and the installed page reported a verified account identity through LiveAPI. No host, account, domain, address, email, credential, or session detail is recorded here.

This evidence does not verify provisioning, lifecycle controls, metrics, configuration, backups, or a supported production matrix. Those remain release gates.

The test uses cPanel's documented [`create_user_session` single-sign-on flow](https://api.docs.cpanel.net/guides/guide-to-api-authentication/guide-to-api-authentication-single-sign-on).
