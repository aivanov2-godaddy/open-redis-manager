# cPanel icon registration refresh — 2026-11-20

## Test identity

- ORM source commit: `9010412` (PR #116).
- Host purpose: owner-designated cPanel test system.
- OS, cPanel release, architecture, and PHP runtimes: not captured in this registration check.
- cPanel theme: Jupiter.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| cPanel plugin archive acceptance | PASS | The cPanel `install_plugin` utility returned `Plugin installed ok` for the icon registration refresh. |
| Group and feature registration | PASS | The generated Jupiter dynamic UI entries reference the registered group and feature icons. |
| Icon asset installation | PASS | cPanel's Jupiter application icon directory contains the registered SVG assets and the feature PNG fallback. |
| Browser rendering | NOT RUN | No authenticated browser screenshot or pixel-level visual review was captured in this check. |
| ORM install, lifecycle, or host compatibility | NOT RUN | This check refreshed cPanel plugin registration only. |

## Result

- Overall result: the updated transparent icon package was accepted and registered by cPanel on one test system.
- Evidence: [PR #116](https://github.com/aivanov2-godaddy/open-redis-manager/pull/116) contains the icon assets and passing CI checks.
- Known limitations: the icon's appearance in an authenticated Jupiter browser session was not captured. This is not full installer or lifecycle validation and does not establish a supported cPanel version.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record omits the hostname, IP address, domain, account names, credentials, session URLs, private keys, and raw operational output.

## Icon-only registration refresh — 2026-11-20

- ORM source commit: `1526e3d` (current `main` after PR #119).
- A package containing only `install.json` and the four current Jupiter SVG/PNG icon assets was passed to cPanel's `install_plugin --theme jupiter` command.
- The command returned `Plugin installed ok` and reported that it scheduled a sprite update. No ORM service, Redis/Valkey container, account data, or other package files were included in the archive.
- The command completed successfully, but the scheduled sprite job and authenticated browser rendering were not observed. The screenshot in [`screenshots/previews/cpanel-registration-icons.png`](../../../screenshots/previews/cpanel-registration-icons.png) is a local render of the current assets, not a live cPanel capture.
