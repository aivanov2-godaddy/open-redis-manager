# Recovering an interrupted ORM file update

`packaging/apply-release.sh` writes its transaction workspace under `/var/cpanel/orm/updates/transaction.*` before replacing managed files. Ordinary command failures trigger an automatic rollback. If rollback cannot complete, or the process is interrupted, the workspace is retained and later update attempts stop until it is reviewed.

## Before recovery

1. Do not start another update, install, upgrade, or uninstall operation.
2. Confirm no updater process is still running and take a server snapshot using the host's normal procedure.
3. As root, inspect the retained workspace, `journal`, `actions.txt`, `backup/`, and `install-manifest.old`. Do not follow symlinks or run commands copied from the workspace.
4. Verify the workspace is a real directory owned by root with mode `0700`; its journal and backup files must be regular root-owned files.

The normal recovery path contains the old v3 install manifest and a copy of each file that was replaced or normalized. An `add` action had no prior file. An `adopt` action means a regular, root-owned file already matched the candidate's signed content and mode but was missing from the old manifest; recovery validates that exact file and leaves it in place while restoring the old manifest. A `normalize` action records the prior file digest and backs up its original CRLF bytes; recovery restores those bytes and the old manifest. The action records include the fixed target and candidate digest; the signed install map and its hard-coded allowlist constrain those targets to ORM-owned paths.

## Recovery command

The installed recovery command is `/usr/local/cpanel/3rdparty/orm/packaging/recover-release.sh`. It shares the lifecycle lock with install, upgrade, and update operations. If that command is unavailable, run `packaging/recover-release.sh` from the exact ORM source revision that created the interrupted transaction. First list and inspect the exact retained transaction ID:

```sh
sudo bash /usr/local/cpanel/3rdparty/orm/packaging/recover-release.sh --list
sudo bash /usr/local/cpanel/3rdparty/orm/packaging/recover-release.sh --preview transaction.ID
```

Review the preview and take the host snapshot before explicitly confirming that same ID:

```sh
sudo bash /usr/local/cpanel/3rdparty/orm/packaging/recover-release.sh --confirm transaction.ID
```

The command validates the root-owned journal, action list, old manifest, every required backup, and every current target before the first change. It accepts a target only when its content is the recorded old or candidate digest. It then restores replaced and normalized files atomically, removes only exact candidate files added by the interrupted update, preserves exact adopted files, restores the old manifest, validates the restored installation and WHM registration, appends a rollback audit outcome, and removes the recovery workspace. If interrupted during recovery, run preview and confirmation again with the same ID; already-restored files are recognized by their recorded old digest. A completed transaction is never rolled back by this command. Any unknown file state, malformed journal, unsafe path, or missing backup stops recovery and preserves the workspace for administrator review.

If the recovery command is unavailable or its validation fails, do not guess at manual commands. Preserve the workspace and use the host snapshot with cPanel support.

## Manual restoration (legacy releases)

Use the transaction journal and installed manifest to inspect every action:

- For each `replace`, restore `backup/<key>` to the recorded fixed target, preserving its saved owner and mode. Use a temporary file in the target's directory and atomic rename after verifying the parent path is a real, root-owned directory.
- For each `add`, remove the target only if it is a regular file and its SHA-256 still equals the candidate digest in `actions.txt`. If it differs, preserve it and stop for administrator review.
- For each `adopt`, preserve the existing file; adoption only adds its exact signed identity to the new manifest, and rollback restores the old manifest without changing that file.
- For each `normalize`, require the original digest recorded in the journal and a backup that normalizes to the signed candidate; restore the backup on rollback.
- Restore `install-manifest.old` to the installed-manifest path using a same-directory temporary file, root ownership, mode `0600`, and atomic rename.
- If a systemd unit was changed while the broker was inactive, run `systemctl daemon-reload` after restoring all unit files. The updater refuses broker/systemd changes while the broker is active.
- Verify the restored manifest against all installed ORM files, verify WHM registration, and confirm the broker's previous enabled/active state before removing the retained transaction directory.

The updater does not modify Redis/Valkey instance data, account records, credentials, backend choice, provider policy, cPanel plugin registration, or WHM AppConfig. Do not restore or remove those paths as part of ORM update recovery. If any file is missing from the recovery workspace, its digest differs unexpectedly, or service state cannot be verified, stop and use the host snapshot with cPanel support rather than guessing.

Linux integration CI exercises a hard process termination after an atomic managed-file replacement but before the next journal checkpoint. It verifies that the prior manifest, root-owned transaction journal, and file backup remain available, that account and Redis fixture data is unchanged, that no success audit entry is written, and that a retry fails closed. This is isolated fixture evidence; it does not replace live cPanel interruption and manual-recovery validation.

The audit log at `/var/cpanel/orm/updates/update-audit.jsonl` contains fixed metadata fields (actor, versions, artifact digest, timestamp and outcome); recovery records also include the transaction ID to make audit retries idempotent. It does not contain credentials or file contents. Process termination can occur before an outcome record is appended, so the retained transaction journal is authoritative for an interrupted transaction.
