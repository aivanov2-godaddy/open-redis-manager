# Installed WHM ownership recovery — 2026-11-22

## Test identity

- ORM candidate: `0.1.0-rc.13`, source commit `2becf755297b097c9288968cf417cb52a556fbf5`
- Test date: 2026-11-22
- Host purpose: owner-designated disposable cPanel & WHM test system
- OS and architecture: AlmaLinux 10.3, x86_64
- cPanel & WHM: 138.0 (build 27), RELEASE
- PHP used by the live harness: cPanel EA PHP 8.5 CLI with cURL and POSIX support
- Backend: native Valkey; an existing account-owned EA Podman Redis cache was retained

## Scenario results

| Scenario | Result | Sanitized evidence |
|---|---|---|
| Signed source-matched update preview and apply | PASS | The candidate signature and source matched the merged rc13 commit. Preview reported 12 replacements and 54 unchanged files, with no conflicts, moves, adoptions, or retirements. The supported updater applied it directly and verified the rc13 installation manifest and managed files. |
| Backend selection and disposable instance | PASS | Authenticated WHM selected the detected native Valkey backend for future instances. Authenticated cPanel provisioned one account-scoped ORM instance from the fixed generic preset; the v3 manifest recorded Valkey and the service reached active state. |
| Stop and controlled ownership drift | PASS | Authenticated cPanel stopped the instance. A single-link regular sentinel with known test bytes was created inside its private data directory and changed to root ownership and mode `0644`; no other data-tree entry was changed. |
| Authenticated WHM scan | PASS | Root WHM SSO submitted the fixed recovery scan. The response exposed the ownership finding and fixed repair option and stated that the scan was recorded in the system authentication log. |
| Authenticated WHM repair | PASS | Root WHM SSO submitted the fixed `ownership_fix` action. The response confirmed repaired ownership and private modes, a stopped current state, that the service was not started, and an audit event. |
| Post-repair file and service state | PASS | The sentinel remained a single-link regular file. Its SHA-256 matched the pre-repair value, owner and group matched the cPanel account, mode was `0600`, and the systemd service remained inactive. One successful stopped-state ownership-repair audit event was present. |
| Existing EA Podman cache | PASS | The sanitized inventory SHA-256 after validation matched the captured pre-test baseline. The cache was not modified. |
| Temporary test-state cleanup | PASS | The sentinel and temporary backend-selection policy were removed/restored to their pre-test state. The temporary release bundle and live harness were removed from the host. Four pre-existing staged updater files were preserved. The disposable ORM instance remains registered and stopped because ORM has no supported instance-delete action; its data was not manually removed. |
| Running-service and unsupported-tree protections | PASS (source fixtures) | Broker fixtures verify repair refusal while the service is active and fail-closed rejection of hard links, symlinks, special files, unsafe owners, and over-limit trees. See the [host fixture record](2026-11-22-whm-ownership-recovery-host-fixtures.md). |

## Result and limits

The installed broker, supported updater, authenticated WHM scan/repair form, on-disk repair, stopped-service invariant, audit event, and preservation of the separate EA Podman inventory passed on this one test host. The source fixture suite covers active-service refusal and unsupported tree entries. This does not establish compatibility across cPanel/WHM versions, operating systems, PHP handlers, CloudLinux/CageFS configurations, or production workloads. The overall host support matrix and browser review remain open.

The live SSO harness is [`tests/whm-live-recovery-form.php`](../../../tests/whm-live-recovery-form.php). It requires root on a disposable cPanel host and an explicit `--confirm-live-operation` flag. It allows only fixed backend selection, provision, stop, scan, and ownership-repair submissions; output excludes host, account, session, and response-body data.

## Sanitization review

This record contains no hostname, IP address, domain, account name, credential, API token, session URL, private key, secret value, or raw operational log. The temporary test signing key was not installed as persistent trust and was not included in the repository or release bundle.
