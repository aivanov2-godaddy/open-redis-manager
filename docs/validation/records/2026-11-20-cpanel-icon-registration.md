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

## PNG launcher refresh — 2026-11-20

- The owner reported that Jupiter displayed the launcher as a solid red block. The installed feature SVG matched the repository source hash, so the problem was not an outdated repository asset.
- A registration archive containing the 32×32 group SVG and transparent 48×48 launcher PNG was accepted by `install_plugin`; it returned `Plugin installed ok` and scheduled another sprite refresh.
- cPanel retained the previously installed `open_redis_manager.svg` despite its absence from the refresh archive. That exact generated feature asset was copied to a root-only backup outside the repository and removed; the registration was then applied again. The Jupiter application icon directory subsequently contained the PNG only, with a hash matching the packaged launcher PNG.
- No ORM service, Redis/Valkey container, account data, or other plugin files were touched. The sprite task and authenticated browser rendering were not observed, so the corrected live appearance remains unverified. The local preview documents the package assets only.

## Cache-busted icon refresh — 2026-11-20

- After a cPanel browser screenshot still showed the earlier solid red tile, the feature and group icon filenames were changed to fresh `orm-cpanel-*-v2` names. The actual icon artwork and the primary README logo were left unchanged.
- An icon-only package containing the updated `install.json`, 32×32 group SVG, and transparent 48×48 PNG assets was accepted by `install_plugin`. cPanel scheduled a sprite update.
- The Windows browser capture helper could not capture the monitor (`IGraphicsCaptureItemInterop.CreateForMonitor` returned `0x80070057`), so the final browser appearance has not been verified. This remains a registration result, not a visual confirmation.
- No ORM service, account data, Redis/Valkey container, or broker state was changed.
