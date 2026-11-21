# Show PhpRedis readiness for the cPanel runtime

**Milestone:** 0.2.0 — Operations and lifecycle completeness
**Status:** implementation in review

## Goal

Help cPanel users see whether the PHP runtime serving ORM currently has PhpRedis, and explain how this relates to their sites' selected PHP runtimes.

## Acceptance criteria

- Detect `extension_loaded('redis')` and a non-autoloaded `Redis` class in the current cPanel request runtime.
- Show the extension version when available, or say it is not detected in this runtime.
- Never claim the result describes each domain's PHP handler or proves application connectivity.
- Tell users that PHP sites using PhpRedis need the extension in their own selected runtime; non-PHP clients do not depend on it.
- Do not inspect application config, execute package commands, or change PHP selection/extensions.
- Add docs, automated UI assertions and a synthetic screenshot.

## Validation limits

Automated checks verify the interface claims and escaping. A source-matched cPanel browser check is still needed to verify how the extension appears across cPanel PHP runtimes and domain handlers.
