# cPanel icon registration refresh — 2026-11-20

## Correction to earlier rendering hypotheses

The earlier sections below preserve the sequence of investigations, but several explanations were hypotheses and should not be treated as established root cause. A later inspection found that cPanel's generated Jupiter sprite contains the group and feature paths, and its CSS points at the expected sprite offsets. The reason the user's browser screenshot showed a solid red tile remains undetermined; a stale or transformed-path explanation is not proven. This follow-up replaces the full-background tile with transparent, single-color red line art to remove the tile that visually dominated the icon. It does not change the approved main README logo. The v3 package preview is local artwork only; registration and authenticated browser rendering must still be checked.

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

- ORM source commit: `ec8b326`.
- After a cPanel browser screenshot still showed the earlier solid red tile, the feature and group icon filenames were changed to fresh `orm-cpanel-*-v2` names. The actual icon artwork and the primary README logo were left unchanged.
- An icon-only package containing the updated `install.json`, 32×32 group SVG, and transparent 48×48 PNG assets was accepted by `install_plugin`. cPanel scheduled a sprite update.
- The Windows browser capture helper could not capture the monitor (`IGraphicsCaptureItemInterop.CreateForMonitor` returned `0x80070057`), so the final browser appearance has not been verified. This remains a registration result, not a visual confirmation.
- No ORM service, account data, Redis/Valkey container, or broker state was changed.

## Approved cache-cube refresh — 2026-11-20

- ORM source commit: `7821269`.
- The cPanel Jupiter group and launcher were changed to use the already approved red-tile/white-cube artwork from the README and WHM mark. The README logo file itself was not modified.
- The icon-only archive was accepted by cPanel and a sprite refresh was scheduled. The installed 48×48 launcher PNG has the same SHA-256 digest as the packaged PNG.
- The local package preview is [`screenshots/previews/cpanel-registration-icons.png`](../../../screenshots/previews/cpanel-registration-icons.png). It documents the supplied assets; it is not a live cPanel screenshot. Browser appearance remains unverified because no authenticated Jupiter capture was available.
- No ORM service, broker state, Redis/Valkey instance, or account data was changed by this icon-only registration.

## Pixel-space SVG refresh — 2026-11-20

- The owner-designated cPanel test system accepted the icon-only ZIP with `install_plugin --theme jupiter` and scheduled a sprite refresh.
- Inspection of cPanel's installed Jupiter application icon showed that its sprite processing rewrites SVG `<rect>` width and height values to the icon's pixel dimensions, while preserving the viewBox. The previous 256-unit viewBox therefore did not match cPanel's transformed SVG.
- The group and launcher SVGs now use 32×32 and 48×48 viewBoxes, respectively, with the existing approved cache-cube artwork scaled into those pixel coordinate spaces. The installed launcher SVG contains the expected 48×48 viewBox and correctly scaled background geometry; the 48×48 PNG fallback remains present.
- Browser rendering was not captured, so visual appearance in Jupiter is still unverified. No ORM service, broker state, Redis/Valkey instance, or account data was changed.

## Flattened SVG path refresh — 2026-11-20

- The owner supplied a Jupiter screenshot showing only the red background tile for both ORM icons. The packaged and installed SVGs had the cube artwork inside a scaled `<g>`, indicating that cPanel's generated sprite did not display those transformed paths.
- The same approved artwork was retained. The scale was applied to each path coordinate and stroke width so all artwork is expressed directly inside the group and launcher pixel-space viewBoxes; the PNG fallback and README logo were not changed.
- An icon-only ZIP with `install.json` and the four SVG/PNG assets was accepted by cPanel's `install_plugin --theme jupiter`. cPanel scheduled the sprite update. The installed group and feature SVGs contain the flattened paths, and the spritemap modification time advanced after the update.
- I extracted the exact group and feature entries from cPanel's regenerated spritemap and rasterized them locally; both generated sprite entries show the complete cube and tile. A post-update authenticated browser capture could not be made because Windows screenshot capture returned `GetCursorPos failed: Access is denied`; appearance in the browser remains unverified, and a hard refresh may be needed to discard cached assets.
- No ORM service, broker state, Redis/Valkey instance, account data, or WHM package was changed by this icon-only refresh. No host, account, credential, session URL, or raw operational output is recorded here.

## Sprite cache-key refresh — 2026-11-20

- The owner supplied a later Jupiter screenshot that still showed the registered ORM icons as solid red tiles.
- The installed group and launcher assets matched the approved package, and the generated SVG sprite contained their cube paths. The stylesheet still referenced an earlier cache key for that sprite, so a browser could continue using the red-only cached sprite.
- Rebuilt the Jupiter sprite from cPanel's installed icon directory, then updated only the stylesheet's sprite cache key to the SHA-256 digest of the generated SVG. A root-only copy of the previous stylesheet was kept outside the repository for rollback.
- The repository installer, upgrade and uninstall flows now refresh that generated cache key after cPanel regenerates its sprites. This makes future icon registration changes fetch the current sprite.
- The authenticated browser appearance was not recaptured; Windows screen capture returned a black frame. The server-side CSS points at the regenerated SVG, but visible rendering still needs browser confirmation after a hard refresh.
- No ORM service, broker state, Redis/Valkey instance, account data, or WHM package was changed. No host, account, credential, session URL, or raw operational output is recorded here.

## Follow-up registration and cache synchronization — 2026-11-20

- Re-registered the current versioned group and launcher assets with an icon-only package. The four installed SVG/PNG files match the repository package by SHA-256.
- cPanel's `sprite_generator` regenerated the Jupiter sprite, then ORM's cache refresh updated the stylesheet URL to the generated SVG's SHA-256. The final sprite hash and stylesheet cache key match.
- The package helper now runs cPanel's sprite generator synchronously before calculating the cache key, preventing the delayed `install_plugin` sprite update from leaving a stale URL. The isolated cPanel installer test covers this cache-key rewrite.
- The authenticated browser appearance was not captured in this run; the existing image remains a local render of the packaged assets. A browser hard refresh and visual confirmation are still pending.
- No ORM service, broker state, Redis/Valkey instance, account data, or WHM package was changed by this icon-only registration and sprite refresh. No host, account, credential, session URL, or raw operational output is recorded here.

## Transparent cPanel icon redesign — 2026-11-20

- Replaced the cPanel-only full red tile and white cube with a transparent Redis-red outline of a three-tier cache cube and inset keyspace diamond. The icon is kept separate from the approved README mark.
- Registered fresh v3 filenames in `install.json` so cPanel can treat the redesign as new Jupiter assets. The group SVG uses a 32×32 viewBox; the feature SVG uses 48×48, with matching 48×48 transparent PNG fallbacks.
- Added pixel checks for transparent PNG corners and red foreground pixels, plus SVG checks for direct path geometry, single-color strokes, and no background shapes. Added a local preview at [`screenshots/previews/cpanel-icons-v3-preview.png`](../../../screenshots/previews/cpanel-icons-v3-preview.png).
- The icon-only archive was accepted by the designated cPanel test system. The installed group and feature SVGs match the v3 package hashes; the generated feature view and stylesheet reference the 48×48 launcher. The authenticated browser appearance was not captured, so the local preview must not be mistaken for a live cPanel screenshot.
- The temporary icon-only archive was removed from the test host after registration. No ORM service, Redis/Valkey instance, account data, or cPanel settings outside the icon registration and regenerated sprite were changed.

## Live generated-sprite and fallback refresh — 2026-11-20

- On the designated test system, the installed group and launcher SVG hashes matched the packaged v3 artwork, but the Jupiter stylesheet's sprite URL cache key did not match the generated sprite SVG's SHA-256. A stale browser sprite was a plausible explanation for the red-block screenshot, but the authenticated browser view was not available to confirm that cause.
- Re-ran the repository's guarded `orm_refresh_cpanel_icon_sprite_cache_key` after the registration's queued sprite work had settled. The final stylesheet key now matches the current generated sprite digest.
- Updated the installed 32×32 group and 48×48 launcher PNG fallback files to match the packaged v3 artwork by SHA-256. The registered SVGs and both PNG fallbacks now match the repository assets.
- Added [`cpanel-jupiter-live-sprite-preview.png`](../../../screenshots/previews/cpanel-jupiter-live-sprite-preview.png), rendered locally from the two icon viewBoxes in the generated cPanel sprite. It shows the actual server-generated icon paths, not a browser capture.
- Authenticated browser appearance after the cache refresh remains unverified. No ORM service, Redis/Valkey instance, account data, or unrelated cPanel configuration was changed. A root-only rollback archive was retained outside the repository; no host, account, credential, session URL, or raw operational output is recorded here.

## Approved-mark cPanel refresh — 2026-11-20

- The owner supplied a cPanel screenshot in which the ORM entries appeared as solid red blocks. The repo's then-current cPanel assets and generated sprite contained the intended transparent outline, so that source rendering did not explain the screenshot.
- Added versioned v4 group and launcher SVGs with direct pixel-space paths, plus matching 48×48 PNG fallbacks, rendered from the already-approved ORM mark. The README logo itself was not changed.
- The cPanel `install_plugin` script accepted the v4 icon package. Its group icon must be SVG; a PNG-only group package was rejected and was not used as the final registration.
- Regenerated the Jupiter sprite synchronously and updated the stylesheet cache key to the SHA-256 digest of that exact sprite. The generated sprite contains the full v4 red tile and white cache cube for both group and launcher. Installed group SVG, launcher SVG, and launcher PNG hashes match the packaged assets.
- The repo includes a local [v4 asset preview](../../../screenshots/previews/cpanel-icons-v4-preview.png). An authenticated cPanel browser screenshot after the refresh was not available, so the actual browser view remains to be visually confirmed. No ORM service, Redis/Valkey instance, account data, or unrelated cPanel settings were changed.
