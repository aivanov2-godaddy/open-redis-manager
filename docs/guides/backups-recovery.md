# Backups and recovery

## Backup behavior

- Keep each snapshot associated with its account, backend, creation time and size.
- Enforce provider retention and show when older snapshots will expire.
- Fleet backups must complete independently per account and expose partial failures.
- Snapshots are explicit; do not enable persistence or schedule backups without clear policy.

## Restore behavior

1. Verify the selected snapshot belongs to the current account or the WHM-authorized target.
2. Explain service impact and expected write-loss window before confirmation.
3. Make a safety snapshot of the current data.
4. Restore with minimum required permissions; validate files and service health.
5. Keep the safety copy until the operator verifies the result.

## Recovery behavior

Run a read-only scan first. Show exact account-level findings and suggested repair. Apply only the selected repair: service restart, config rebuild from trusted metadata, credential rotation or narrow ownership repair. Record actor, target, status and result while excluding secrets. Never use a global permissions reset as a routine recovery shortcut.
