# cPanel first-run wizard live validation

**Date:** 2026-11-22
**Product version:** ORM `0.1.0-rc.13`
**Host:** one disposable cPanel & WHM `11.138.0` test host
**Source:** merged `main` at `fe0e18a22da5677a052bd20a503f2e4b661b2851`

## Scope and source match

The installed cPanel page SHA-256 matched the repository `packaging/cpanel/files/orm/index.live.php` at the source commit. The installed `PodmanCacheDiscovery.php` also matched; seven additional cPanel identity, request-guard, broker-client, backend-discovery, and EA Podman setup files matched the same source. The test did not update the installed package.

A dedicated disposable cPanel account was created for this check. It had no ORM instance and no `ea-podman.d` directory. Its account name and test domain are omitted. Existing ORM instances and EA Podman containers were not used as test targets or changed.

## Results

- The authenticated cPanel first-run landing page displayed both backend choices.
- Fixed `orm_setup=native` and `orm_setup=podman` GET routes each returned HTTP 200 with the expected setup heading and return link.
- The native route rendered the host's standard Redis/Valkey binary discovery results. The host already had native binaries, so the native-missing administrator installation branch was not exercised.
- The verified-empty account's Podman route displayed the fixed cPanel commands for `ea-redis62` and `ea-valkey72`, a **Check again** link, and cPanel administrator setup guidance.
- `tests/cpanel-live-smoke.py --require-first-run-setup` passed. It verified the account identity and rendered first-run routes; response bodies, account identity, domain, SSO URL, and session token were not saved.
- Additional in-memory marker checks confirmed both fixed Podman commands and the native binary-discovery section. No installation command or state-changing HTTP request was sent.

## Browser screenshots

Authenticated browser captures were taken from the same cPanel installation. They show the generic first-run choice, native discovery, and EA Podman guidance. The account identity display was removed from the rendered page before capture. No hostname, account name, domain, SSO URL, or session token is included.

| View | Screenshot | SHA-256 |
|---|---|---|
| Backend choices | [PNG](../../../screenshots/validation/cpanel-first-run-choices-live.png) | `dc71b3ddf18de87fa62b9c0c08a66fa9ed100b29c17562b7279c2f4ae025abe9` |
| Native backend | [PNG](../../../screenshots/validation/cpanel-first-run-native-live.png) | `c1b34914678f7fdd21569b065649614d72ea3ae00e6b44d507ca87ec2516b1d2` |
| EA Podman backend | [PNG](../../../screenshots/validation/cpanel-first-run-podman-live.png) | `17c204b322603e79c399746c0888d4ce14af6f06d9fae911c46eb578d25c07c8` |

## Limits

This proves the first-run route flow and rendered UI on one cPanel version and one host only. It is not a supported-host declaration or an installation test. No Redis/Valkey package was installed, no WHM backend selection or provider policy changed. The native-missing branch and broader operating-system/cPanel matrix remain open.
