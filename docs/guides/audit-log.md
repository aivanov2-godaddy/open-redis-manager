# WHM audit log

The root WHM addon can search ORM operational events and download a normalized JSON report. The page submits filters with POST on the current WHM session route so account names and date filters do not appear in the URL.

## Search

Select a UTC date range of no more than seven days. Optional filters include a cPanel account name (or `global`), one fixed ORM action, and a result token. Queries inspect only the `orm-broker` and `orm-whm` identifiers in the host's `authpriv` journal. Results contain event time, source, actor UID, account, action, result, and state. Records are sorted newest first and shown in pages of 50; each query is bounded to a maximum of 1,000 normalized records.

The reader invokes the fixed `/usr/bin/journalctl` program with an argument vector, a 3-second timeout per source, a 1 MiB output bound per source, and a 1,001-row query limit. It does not invoke a shell. It accepts only fixed ORM message schemas. Raw journal messages, command output, host paths, Redis keys or values, and passwords are never rendered or exported.

## Coverage and limitations

Each source is identified as complete, partial, or unavailable. Timeouts, truncated output, and unrecognized rows are visible. An empty result does not prove that no operation occurred: the host may have expired, forwarded, or disabled persistent journal records.

The current sources cover privileged WHM fleet controls, diagnostics, recovery, backup/restore, migration, AUTH changes, provider policy decisions, provider policy changes, and backend selection. cPanel provisioning, configuration, start, and stop activity is not currently included. The screen is therefore an ORM operations view, not a complete host audit trail. Follow the server's journal retention, access, and forwarding policy for authoritative retention.

JSON exports include a schema version, UTC range, normalized filters and records, per-source coverage, truncation flags, and limitations. The download response is marked private and no-store. Treat exports as administrative data because account identifiers and actor UIDs are present.
