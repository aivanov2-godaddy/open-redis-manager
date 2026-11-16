# cPanel user guide

> The standalone prototype renders sample data. The installed cPanel entry point has account-scoped initialization, status, start, stop, live and stale metrics, bounded configuration actions, hourly metric history with 24-hour and 7-day charts, explicit account-scoped RDB snapshot creation/list/download/restore with three-snapshot retention, and a previewable credential-redacted diagnostics report. Restore creates a validated safety snapshot and verifies the resulting service state, with an automatic rollback attempt if the restored data fails to start. Initialization offers five fixed workload presets. Root WHM now offers per-account snapshot listing, creation, and restore; fleet-wide batch actions and credential management remain unimplemented. Disposable-host validation is still required.

## Overview

The account page shows service state, current or retained memory, connection count, hit ratio, and sample time. The latest successful sample is retained for up to 30 days, labeled stale when the service is stopped or live sampling fails, and removed after expiry. A separate per-account timer collects one hourly sample while the cache is running; root-owned history is capped at 720 samples/30 days and charted over 24 hours or 7 days.

## Lifecycle and connection details

- Initialize/start and stop only the authenticated cPanel account's instance. See the [instance lifecycle guide](instance-lifecycle.md).
- Show the current private Unix socket endpoint and database. This build has TCP disabled and does not configure a Redis AUTH secret.
- Do not imply a secret exists; future credential handling must reveal or copy only after explicit user action and avoid persisting it in the browser.
- Explain that a compatible application client and application configuration are still required.

## Configuration and apps

Use the [configuration and presets guide](configuration-presets.md). The page offers initial workload presets, controls for memory, eviction policy, clients and timeout, and copyable account-socket settings for PhpRedis, WordPress/WooCommerce, LiteSpeed Cache, Laravel, Magento/Adobe Commerce, node-redis and redis-py. Helpers copy settings only; they do not edit application files or enable application features. Version-specific Commerce instructions remain a guided step.

## Backups and diagnostics

Create account-scoped snapshots within provider retention. Before restore, explain impact and capture a safety snapshot. Diagnostics must be previewable and omit credentials, sessions and unrelated account content.

The installed **Support diagnostics** section previews the exact JSON that the account can download. The report includes bounded state, configuration and latest metrics, and omits account names, hostnames, filesystem paths, credentials, keys, values, application payloads, sessions, logs and raw command output. It is generated in memory and not retained by ORM. See the [monitoring and diagnostics guide](monitoring-diagnostics.md) for its schema and limits.

## Account boundary

The cPanel entry point derives the account identity from cPanel's `Variables::get_user_information` UAPI response and validates it before rendering. It then compares that name with the identity returned by the local ORM broker, which maps the kernel-reported peer UID to a system account and a trusted cPanel account record. It does not accept an account name from query parameters or form fields. Never expose WHM-only controls in the cPanel route. The UAPI request asks only for the `user` value; either identity check failing leaves the page unavailable.

The live smoke test confirmed the LiveAPI username and broker identity match on one test host, but the new service lifecycle has not been validated there. Forms submit through cPanel's session-tokenized interface; broker calls reject submitted identity and derive the target from `SO_PEERCRED`. See the [cPanel LiveAPI guide](https://api.docs.cpanel.net/guides/guide-to-the-liveapi-system/guide-to-the-liveapi-system-php-class) and [cPanel variables reference](https://api.docs.cpanel.net/guides/guide-to-cpanel-variables), which recommends the UAPI Variables functions over deprecated `cpanelprint()` calls.
