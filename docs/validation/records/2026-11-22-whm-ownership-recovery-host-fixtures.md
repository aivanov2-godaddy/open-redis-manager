# WHM ownership recovery host fixture validation

## Test identity

- ORM commit: `329a4f12c043ae40edd7d23341d6bd4f84684263` (source checkout; installed package was not changed)
- Test date (UTC): 2026-11-22
- Tester / review reference: Codex test run; follow-up issue and PR linked from the compatibility matrix
- Host purpose: disposable cPanel test system
- cPanel version and release tier: 11.138.0.27; license tier not verified
- OS name and major version: AlmaLinux 10.3
- Architecture: x86_64
- CloudLinux version, if present: not checked
- CageFS installed/enabled: not checked
- PHP Selector installed/enabled: not checked
- ORM page internal PHP version: not exercised
- EasyApache PHP version(s) exercised: not exercised
- Alt-PHP version(s) exercised: not exercised
- PHP handler(s) exercised: not exercised
- Redis version / package source: not exercised by these tests
- Valkey version / package source: not exercised by these tests

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Fresh install and cPanel/WHM registration | NOT RUN | The installed package was left unchanged. |
| Account identity and cross-account denial | NOT RUN | No live cPanel request was made. |
| WHM ACL and root-only broker authorization | NOT RUN | Fleet authorization fixtures ran; the installed broker socket and authenticated WHM entry point were not exercised. |
| Provision, status, configure, start, stop, restart | NOT RUN | Service operations were isolated behind the test suite's fixed systemd stub. |
| Metrics freshness and stale fallback | NOT RUN | Not part of this focused run. |
| Backup, download, restore, safety snapshot | NOT RUN | Not part of this focused run. |
| Redis-to-Valkey migration and rollback | NOT RUN | Not part of this focused run. |
| Recovery scan and fixed repair | PASS (source fixtures only) | The broker and fleet recovery tests passed from the merged source checkout. The ownership-repair fixture exercised Linux `chown`/`chmod`, verified file bytes and private modes, and rejected unsupported tree entries. The tests used temporary paths and a fixture UID/GID; they did not touch an installed ORM instance. |
| AUTH disabled by default and status | NOT RUN | Not part of this focused run. |
| AUTH enable, rotate, client reconnect, and disable | NOT RUN | Not part of this focused run. |
| AUTH failed restart/probe and previous-state rollback | NOT RUN | Not part of this focused run. |
| AUTH password visibility, refresh behavior, and redaction | NOT RUN | Not part of this focused run. |
| Upgrade, including failure rollback | NOT RUN | No package update was applied. |
| Uninstall with populated user data preserved | NOT RUN | No uninstall was performed. |
| Missing required binary | NOT RUN | Not part of this focused run. |
| Bad ownership / permissions | PASS (source fixtures only) | The test suite detected and repaired fixture ownership/mode drift while preserving contents; symlink, hard-link, special-file, and scan-limit cases remained fail-closed. |
| Full disk / ENOSPC | NOT RUN | Not part of this focused run. |
| Failed rollback and retained recovery state | NOT RUN | Not part of this focused run. |
| CageFS / PHP Selector socket visibility | NOT RUN | Not part of this focused run. |

## Result

- Overall result: PASS for the focused source-level Perl suite on this host; 697 tests passed with the root runner.
- Known limitations: The suite used temporary fixtures and a stubbed systemd callback. It did not load the checked-out source into the installed `orm-broker`, submit an authenticated WHM form, or repair a live ORM-managed instance. The installed package remained at its previous version, and the existing EA Podman service was left untouched.
- Follow-up issue(s): [#244](https://github.com/aivanov2-godaddy/open-redis-manager/issues/244) tracks the authenticated WHM recovery scan and repair on an installed, disposable ORM-managed instance before marking the cPanel recovery gate complete.
- Reviewer: pending
- ORM support decision: `NOT ESTABLISHED`

## Sanitization review

This record contains no hostname, IP address, domain, account name, credential, API token, session URL, private key, secret value, or raw operational log.
