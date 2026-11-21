# Issue #197 — cPanel first-run backend setup wizard

GitHub issue: https://github.com/aivanov2-godaddy/open-redis-manager/issues/197

## Goal

Let a cPanel account choose an ORM-managed native Redis/Valkey service or a cPanel EA Podman container. Detect what can be verified, distinguish missing from unknown prerequisites, and guide installation using the supported owner/admin context.

## Acceptance and implementation notes

- Show a first-run choice only when neither an ORM-managed instance nor a verified account-owned EA Podman cache exists.
- Native service discovery uses the existing fixed-path read-only binary discovery. Host package installation and WHM backend selection remain administrator/provider responsibilities; the cPanel user cannot bypass broker policy.
- EA Podman discovery is scoped to the authenticated cPanel account. It checks `/etc/os-release` against cPanel-supported OS identifiers, verifies a normal non-jailed shell, and runs only the fixed read-only `ea-podman avail` command with a four-second timeout and 8 KiB output cap.
- The wizard offers only cPanel's fixed `ea-redis62` and `ea-valkey72` package instructions. The cPanel user runs installation in their own Terminal/SSH session, then ORM rescans and verifies the account-owned directory/socket. No image, package, command, path, or container name is user-selectable.
- The cPanel page does not run an OS package manager, edit kernel/user-namespace policy, or install Podman synchronously in a web request. Administrator host prerequisites are explicit; user-namespace availability remains administrator-verified.
- Unsafe/unreadable inventory, missing tool, unsupported shell/host, command failure, timeout, and unrecognized output remain distinct from verified absence.
- Tests cover fixed invocation, account identity, package inventory parsing, timeouts, unsupported shell/host, and account-owned container inventory isolation.
- Standalone guide added at `docs/guides/cpanel-first-run-setup.md`; README and catalog updated.

## Validation remaining

The new cPanel page still needs screenshot review and source-matched live validation on the disposable cPanel host. This branch must not claim a supported host matrix or automatically installed packages.
