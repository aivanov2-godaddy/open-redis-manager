# cPanel user guide

> The prototype renders this workflow with sample data. A production account-safe implementation is planned.

## Overview

The account page should show service/backend state, allocated and used memory, connection count, hit ratio, health/preflight checks and sample time. Temporary monitoring failures should retain last-known values and mark them stale.

## Lifecycle and connection details

- Initialize/start and stop only the authenticated cPanel account's instance.
- Show the private endpoint, port, database and a secret masked by default.
- Reveal/copy a secret only after explicit user action and avoid persisting it in the browser.
- Explain that a compatible application client and application configuration are still required.

## Configuration and apps

Use the [configuration and presets guide](configuration-presets.md). The application helper should include WordPress, LiteSpeed Cache, Laravel, Magento, PHP, Node.js and Python examples with placeholders unless the account user asks to reveal credentials.

## Backups and diagnostics

Create account-scoped snapshots within provider retention. Before restore, explain impact and capture a safety snapshot. Diagnostics must be previewable and omit credentials, sessions and unrelated account content.

## Account boundary

Derive the account identity from cPanel's authenticated context on the server. Ignore or reject a user-submitted account name. Never expose WHM-only controls in the cPanel route.
