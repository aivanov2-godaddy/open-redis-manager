# cPanel user guide

> The standalone prototype renders sample data. The installed cPanel entry point now reads and displays only the current authenticated username from cPanel LiveAPI; the Redis account manager remains unimplemented.

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

The cPanel entry point derives the account identity from cPanel's `Variables::get_user_information` UAPI response and validates it before rendering. It does not accept an account name from query parameters or form fields. Never expose WHM-only controls in the cPanel route. The UAPI request asks only for the `user` value and the reader fails closed unless the response reports success and contains a valid username.

This identity check does not yet provide account instance isolation because there is no instance registry or service adapter. See the [cPanel LiveAPI guide](https://api.docs.cpanel.net/guides/guide-to-the-liveapi-system/guide-to-the-liveapi-system-php-class) and [cPanel variables reference](https://api.docs.cpanel.net/guides/guide-to-cpanel-variables), which recommends the UAPI Variables functions over deprecated `cpanelprint()` calls.
