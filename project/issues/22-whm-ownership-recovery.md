# Add safe WHM ownership recovery

GitHub issue: [#242](https://github.com/aivanov2-godaddy/open-redis-manager/issues/242)

## Goal

Add a scan-guided WHM repair for restoring ownership metadata on an ORM-managed account data tree after a stopped service becomes unavailable because supported managed paths have incorrect ownership or permissions.

## Acceptance criteria

- Require a trusted root-owned manifest and a freshly resolved cPanel account UID/GID; manifest paths must match exact canonical per-account paths.
- Report normalized ownership findings and offer repair only for a stopped or failed service.
- Repair only the bounded managed account data tree, with no-follow checks; refuse symlinks, hard links, special files other than the canonical Redis socket, unexpected paths, unsafe traversal, and resource-limit overflow.
- Preserve Redis data and configuration contents; re-scan and verify ownership/modes before returning success, and leave the service stopped.
- Keep the WHM action fixed, authenticated, CSRF-protected, rate-limited, and recorded through the metadata-only audit schema.
- Add focused Linux tests for valid repair and adversarial path/ownership failures, plus operator docs, feature catalog, release notes, and live validation status.

## Current implementation scope

The repair supports directories, single-link regular files, and the canonical `redis.sock` socket entry under the account data directory. It normalizes directories to `0700` and files/socket to `0600`, examines at most 10,000 entries and 64 directory levels, reads no file contents, and leaves the service stopped.

## Live validation

Merged [PR #247](https://github.com/aivanov2-godaddy/open-redis-manager/pull/247) validated a current-source cPanel provisioning and stop flow followed by authenticated WHM scan and ownership repair on one AlmaLinux 10.3 / cPanel & WHM 138.0 RELEASE test host. The repair preserved the sentinel file bytes, restored account ownership and mode `0600`, left the service stopped, and emitted the expected audit event. The separate EA Podman Redis inventory remained unchanged. See the [sanitized live record](../../docs/validation/records/2026-11-22-whm-ownership-recovery-installed-live.md) and [host fixture record](../../docs/validation/records/2026-11-22-whm-ownership-recovery-host-fixtures.md).

This confirms one host and one live repair scenario only. Broader operating-system, cPanel/WHM version, PHP runtime, and browser coverage remain open.
