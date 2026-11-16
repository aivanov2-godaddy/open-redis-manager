# Backups and recovery

## Backup behavior

The cPanel page creates, lists, downloads, and restores explicit RDB snapshots for the signed-in account. Root WHM can list up to three retained snapshots for displayed accounts, create a snapshot, or restore a selected snapshot for one account at a time, with a result for that account. The broker stores snapshots in root-controlled per-account directories, validates their ownership and size, and keeps the newest three. A snapshot is not Redis persistence: ORM does not schedule backups or enable persistence. Transfer is limited to 128 MiB and 60 seconds. An all-fleet batch with partial-result reporting is not implemented; disposable-host validation remains required.

## Restore behavior

The cPanel restore control is available only while the account's service is running. It accepts an opaque ID from that account's validated backup list; it never accepts a filesystem path. Before confirmation, the page explains that cache access will pause briefly and writes newer than the selected snapshot can be lost.

The broker stages and validates the selected RDB with the installed `redis-check-rdb` or `valkey-check-rdb` binary, creates a safety snapshot, validates that copy, and stops the account service. It atomically installs the selected RDB with account ownership and restrictive permissions, starts the service, and confirms the active state. If startup fails, it attempts to stop the failed process, restore the safety copy, and start the service again. The selected snapshot and new safety snapshot are retained within the three-item limit. A successful receipt identifies both snapshots and the verified service state; a failed receipt includes the safety ID when one was created. The operation is rate-limited and records an audit event without credentials.

If the RDB checker is unavailable, validation fails, or rollback cannot be verified, ORM stops and reports the operation as failed; it does not claim recovery succeeded. Keep independent copies of important data and verify the restored service from the application after the operation. WHM uses the same selected-account restore and rollback flow; all-fleet batch restore is not implemented.

## Recovery behavior

Run a read-only scan first. Show exact account-level findings and suggested repair. Apply only the selected repair: service restart, config rebuild from trusted metadata, credential rotation or narrow ownership repair. Record actor, target, status and result while excluding secrets. Never use a global permissions reset as a routine recovery shortcut.
