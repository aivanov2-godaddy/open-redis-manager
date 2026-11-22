# Backups and recovery

## Backup behavior

The cPanel page creates, lists, downloads, and restores explicit RDB snapshots for the signed-in account. Root WHM can list up to three retained snapshots for displayed accounts and run a bounded batch create or restore for at most two running accounts on the current page. Each restore target must use a retained snapshot listed for that account. Operations run account by account and return separate outcomes, including partial success when one account fails. The broker stores snapshots in root-controlled per-account directories, validates their ownership and size, and keeps the newest three. A snapshot is not Redis persistence: ORM does not schedule backups or enable persistence. Transfer is limited to 128 MiB and 60 seconds. An unlimited or all-fleet batch is not supported, and disposable-host validation remains required.

## Restore behavior

The cPanel restore control is available only while the account's service is running. It accepts an opaque ID from that account's validated backup list; it never accepts a filesystem path. Before confirmation, the page explains that cache access will pause briefly and writes newer than the selected snapshot can be lost.

The broker stages and validates the selected RDB with the installed `redis-check-rdb` or `valkey-check-rdb` binary, creates a safety snapshot, validates that copy, and stops the account service. It atomically installs the selected RDB with account ownership and restrictive permissions, starts the service, and confirms the active state. If startup fails, it attempts to stop the failed process, restore the safety copy, and start the service again. The selected snapshot and new safety snapshot are retained within the three-item limit. A successful receipt identifies both snapshots and the verified service state; a failed receipt includes the safety ID when one was created. The operation is rate-limited and records an audit event without credentials.

If the RDB checker is unavailable, validation fails, or rollback cannot be verified, ORM stops and reports the operation as failed; it does not claim recovery succeeded. Keep independent copies of important data and verify the restored service from the application after the operation. WHM batch restore uses the same validation, per-account safety snapshot, and rollback flow for each selected account. Each target is rate-limited independently, and the batch stops at two accounts per submission; all-fleet batch restore is not supported.

## Recovery behavior

Run a read-only scan first. Show exact account-level findings and suggested repair. WHM can start a verified stopped or failed service. It can also rebuild a noncanonical config only when the root-owned manifest, account paths, config ownership and permissions, database count, bounded core settings, and optional AUTH directive remain valid. The config file must still exist as a safe regular file: ORM cannot recover settings or an AUTH secret that are missing or malformed. Rebuild requires a second confirmation, replaces unrecognized additions with the canonical ORM config, preserves the validated settings and AUTH value, verifies the result, and does not start the service. A fresh scan is required before starting it.

Missing-config recovery, malformed core settings, and narrow ownership repair are not implemented. WHM and cPanel can rotate AUTH using the verified flow described in their respective guides; record actor, target, status and result while excluding secrets. Never use a global permissions reset as a routine recovery shortcut.
