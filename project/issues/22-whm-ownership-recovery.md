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

The repair supports directories, single-link regular files, and the canonical `redis.sock` socket entry under the account data directory. It normalizes directories to `0700` and files/socket to `0600`, examines at most 10,000 entries and 64 directory levels, reads no file contents, and leaves the service stopped. Disposable cPanel validation remains open.
