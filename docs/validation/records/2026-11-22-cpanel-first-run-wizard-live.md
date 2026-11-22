# cPanel first-run wizard live validation

**Date:** 2026-11-22
**Product version:** ORM `0.1.0-rc.13`
**Host:** one disposable cPanel & WHM `11.138.0` test host
**Source:** merged `main` at `0c3b338ecaa1d51112fd162a5fa7c0008da7cd7b`

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

## Limits

This proves the first-run route flow on one cPanel version and one host only. It is not a supported-host declaration or an installation test. No Redis/Valkey package was installed, no WHM backend selection or provider policy changed, and no live browser screenshot was captured. The native-missing branch, browser visual review, and broader operating-system/cPanel matrix remain open.
