# Disposable cPanel validation record

Copy this template for each test run. Use a disposable host and remove all placeholders that do not apply. Publish only the sanitized record after review.

## Test identity

- ORM commit:
- Test date (UTC):
- Tester / review reference:
- Host purpose: disposable test system
- cPanel version and release tier:
- OS name and major version:
- Architecture:
- CloudLinux version, if present:
- CageFS installed/enabled:
- PHP Selector installed/enabled:
- ORM page internal PHP version:
- EasyApache PHP version(s) exercised:
- Alt-PHP version(s) exercised:
- PHP handler(s) exercised:
- Redis version / package source:
- Valkey version / package source:

## Scenario results

Use `PASS`, `FAIL`, `BLOCKED`, or `NOT RUN`. Include a short sanitized observation and link to a redacted CI run or reviewable artifact where available.

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Fresh install and cPanel/WHM registration | | |
| Account identity and cross-account denial | | |
| WHM ACL and root-only broker authorization | | |
| Provision, status, configure, start, stop, restart | | |
| Metrics freshness and stale fallback | | |
| Backup, download, restore, safety snapshot | | |
| Redis-to-Valkey migration and rollback | | |
| Recovery scan and fixed repair | | |
| Upgrade, including failure rollback | | |
| Uninstall with populated user data preserved | | |
| Missing required binary | | |
| Bad ownership / permissions | | |
| Full disk / ENOSPC | | |
| Failed rollback and retained recovery state | | |
| CageFS / PHP Selector socket visibility | | |

## Result

- Overall result:
- Known limitations:
- Follow-up issue(s):
- Reviewer:
- ORM support decision: `NOT ESTABLISHED` unless the full release matrix and required scenarios have passed.

## Sanitization review

Confirm the record and every linked artifact contain no hostname, IP address, domain, account name, password, API token, session URL, private key, secret value, or unredacted operational log.
