# Live cPanel identity smoke after dependency repair — 2026-11-20

## Test identity

- ORM source commit: `9b13f4e` (`main` at the time of the run).
- Host purpose: owner-designated disposable cPanel test system.
- Operating system, cPanel & WHM version/tier, architecture, and PHP handler: not recaptured in this run.
- The cPanel entry point, `AuthenticatedAccountContext.php`, `BrokerIdentityVerifier.php`, and the page's existing PHP helpers matched the repository source by SHA-256. The broker service was active.
- The installed page initially returned HTTP 500 because `ApplicationDiscovery.php`, a required read-only cPanel helper, was absent. That single file was installed from the tested repository revision with root ownership and mode `0644`; its SHA-256 matched the repository. No existing file was replaced.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Live cPanel account identity | PASS | `tests/cpanel-live-smoke.py --user` opened a temporary cPanel SSO session and verified LiveAPI identity against the local broker. The test printed only its pass result. |
| Application discovery or Redis/Valkey operations | NOT RUN | The smoke checks account identity only and performs no application scan, cache command, or lifecycle action. |
| Fresh install, package upgrade, and uninstall | NOT RUN | This was not a package lifecycle test. |

## Installed package state and limitations

- Before the one-file repair, the installed v3 manifest contained 48 records while the current package map expected 49. The expected `application_discovery` record was absent. Several release-updater files and the registered WHM AppConfig also differed from the current checkout.
- No full package update was attempted. The passing smoke therefore verifies the current cPanel identity path after the exact missing helper was installed; it does not verify an exact, synchronized package installation, update eligibility, the release updater, or the host support matrix.
- The installed `ApplicationDiscovery.php` remains on the disposable test system so the cPanel page can load. The existing manifest was not rewritten to claim the wider package matches this checkout.
- Cross-account denial, WHM ACLs, lifecycle controls, metrics, backups, restore, migration, recovery, AUTH, CloudLinux/CageFS, and uninstall remain untested here.

## Result

- Overall result: partial live validation. The current cPanel page's account-identity check passed after a single missing dependency was repaired.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits the hostname, IP address, domains, account name, credentials, API tokens, session URLs, private keys, and raw logs. The temporary test scripts were removed from the host after execution.
