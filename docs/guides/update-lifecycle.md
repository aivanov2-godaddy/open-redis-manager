# WHM update lifecycle

## Reference product behavior

The public reference [update page](https://cpanelredismanager.com/upgrade.php) describes an in-WHM update flow that checks the current product version, applies the current release, and asks the administrator to verify that WHM and cPanel still load, accounts remain visible, provider settings remain available, and the displayed version matches the release. It also states that supported updates preserve existing Redis instances and account configuration. These are vendor claims, not guarantees for ORM.

The reference site also describes a special cleanup path for its own pre-v2.0.3 plugin and an uninstall command that can remove Redis instances and configuration. Those procedures are specific to that commercial product. Do not run them against ORM or another installation.

## ORM status

The repository now includes an offline bundle builder for clean, version-matched source commits. It signs metadata with an external private key and validates the bundle; it does not publish releases or manage signing keys. See the [release signing guide](release-signing.md).

ORM's signed-release workflow requires a root-staged bundle and locally pinned public key. WHM previews the signed candidate against the installed v3 manifest, then requires a separate explicit confirmation before it queues a root-owned asynchronous job. The job is bound to the previewed candidate version and artifact digest, launches through a transient systemd service, and invokes the transaction engine while holding the lifecycle lock. WHM exposes bounded job status and directs interrupted transactions with journals to manual recovery. ORM does not fetch releases automatically or include a production signing service. The release worker and lifecycle have not yet passed live disposable cPanel validation. `packaging/upgrade.sh` provides a narrowly scoped compatibility bridge from the identity-only v1 installation captured by [`packaging/legacy/identity-v1/install.manifest`](../../packaging/legacy/identity-v1/install.manifest). It accepts only an exact file and mode match, a matching registered WHM AppConfig file, and absent instance roots. Any changed file, unknown ORM file, symlink, registration mismatch, or existing instance root causes a refusal before mutation.

After preflight, the transaction creates only the empty root-owned, mode-0711 metadata and data directories required by the broker's systemd write allowlist. It does not create an account instance or touch Redis/Valkey data. If rollback is needed, it removes those directories only when they still match the transaction's recorded identity and remain empty; otherwise recovery stops and preserves them.

The bridge serializes install lifecycle operations, snapshots package files, prevents new broker connections while existing requests drain, reapplies the same cPanel feature IDs through cPanel's `install_plugin` utility, atomically replaces managed files, writes a root-owned file hash manifest, and restores the prior broker enabled/active state. It leaves the already-registered WHM AppConfig file in place and includes its validated hash in the manifest. It rolls back file and cPanel registration changes when a step fails, retaining recovery files if rollback itself is incomplete. It never creates an account instance or changes Redis/Valkey data. Later signed releases use the separate WHM workflow above; this identity-v1 bridge remains a one-time compatibility path. See the [package guide](../../packaging/README.md).

Fresh installs and successful identity-v1 bridge upgrades write install manifest schema v3, including the package's strict semantic version and each managed file's mode, SHA-256, and fixed target path. The validator can read v1 and v2 manifests, but live release preview requires v3 target records. `packaging/adopt-install-manifest.sh` can convert a v1 or v2 manifest to v3 only when every installed file, owner, and mode exactly matches this checkout; a v2 manifest must also report the checkout's exact package version. It holds the lifecycle lock, verifies WHM registration and AppConfig, and atomically replaces only the manifest. It refuses mismatched files, versions, or unsupported manifest schemas without changing package files or service state. This metadata adoption does not migrate an older package or establish release authenticity.

The repository has a signed release-bundle verifier and read-only installed-file preview. The verifier checks detached RSA/SHA-256 signatures against a root-owned pinned key, strict metadata fields, expiry, installed-version compatibility, downgrade rejection, artifact size and digest. It inspects the archive without extracting it and rejects unsafe paths, links, special files, duplicates, unexpected entries, invalid modes, missing package files, size-limit violations, and a mismatched `VERSION`. The signed install map must match the updater's allowlist. The preview reports add, replace, unchanged, move, conflict, and retire actions for v3 manifests. A signed apply may add an allowlisted target only when the existing v3 manifest is a valid subset of the current package map and the new target path is absent; an untracked existing target is a conflict. Normal install, uninstall, and final post-apply validation still require the complete manifest. The raw comparator is explicitly unverified; the preview wrapper marks verification only after signature, digest, compatibility, and archive checks succeed. V1/v2 manifests fail closed for live comparisons until they pass the exact-current-package adoption step above.

The WHM preview invokes only the installed verifier with a fixed argument vector and a 30-second process limit. It reads `release.metadata`, `release.sig`, and `release.tar.gz` from `/var/cpanel/orm/updates/staged/`, and trusts only root-owned public keys in `/etc/orm/release-keys/`. No request parameter can select a path or executable. Create both directories as `root:root` with mode `0700`, place only reviewed public keys there using the verifier's documented `key_id.pem` naming convention, and stage the three files under the fixed names. Private signing keys must remain outside the server and repository. The installer packages the verifier, transaction engine, worker, and runtime support under `/usr/local/cpanel/3rdparty/orm/`. The apply form repeats preview verification and will queue only a conflict-free release; its worker receives a fixed job ID and rechecks the candidate version and artifact digest under the lifecycle lock. See [WHM update preview operations](update-preview.md).

`packaging/apply-release.sh` is the transaction engine for an existing, clean v3 installation. It repeats signed verification and target comparison while holding the lifecycle lock, rejects conflicts, moves, retirements, and migrations, stages only the verified archive, atomically replaces fixed ORM-managed files, updates the v3 manifest, and records success, rejection, rollback, or recovery-required outcomes in the protected updater audit log. Ordinary failures restore replaced files and the previous manifest; an incomplete rollback retains its recovery directory and the next apply refuses to run while a transaction directory remains. Existing Redis/Valkey data, instance records, credentials, backend choice, provider policy, cPanel plugin registration, and WHM AppConfig are not modified. Candidate releases that change WHM AppConfig are refused; updates that change broker or systemd files are refused while the broker is active. The WHM worker executes this engine asynchronously and stores only bounded status; the CLI remains available for controlled maintenance and recovery. A persistent journal supports manual recovery after process interruption; see [update recovery](update-recovery.md).

To exercise the command on a real supported host, run it from a trusted extracted ORM release checkout after placing the signed bundle files and the pinned public key in root-owned, non-writable paths:

```sh
sudo bash packaging/apply-release.sh \
  /root/orm-update/release.metadata \
  /root/orm-update/release.sig \
  /root/orm-update/orm-0.2.0.tar.gz \
  /etc/orm/release-keys \
  0.1.0
```

The command line above is an example format, not a supported-host claim. Review `packaging/preview-release.sh` output first and validate both success and recovery on a disposable cPanel host. The optional final `TEST_TARGET_ROOT` argument exists only for isolated root-owned Linux fixtures. The archive limits are 128 MiB compressed, 640 MiB expanded, 64 MiB per member, and 512 MiB declared file content. Runtime dependencies include Perl `Archive::Tar`, `IO::Uncompress::Gunzip`, `JSON::PP`, and `Digest::SHA`, OpenSSL, GNU `date`, and GNU `timeout` for the WHM preview process bound.

cPanel documents `install_plugin` as the supported way to register a plugin and `uninstall_plugin` as the supported way to remove that registration; the ORM bridge uses both for a reversible replacement ([cPanel plugin installation guide](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins), [`install_plugin` reference](https://docs.cpanel.net/whm/scripts/the-install_plugin-script/), [cPanel plugin uninstall guide](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins/guide-to-cpanel-plugins-uninstall-plugins)).

## Required ORM update design

- Authenticate and authorize the WHM operator before checking or applying an update.
- Display the installed version, selected release, package digest/signature, compatibility result, and affected files before mutation.
- Preserve existing Redis/Valkey selection, account identity, ports, credentials, configuration, and data unless the administrator starts a separate explicit migration.
- Back up ORM-owned metadata, validate it, then apply a versioned migration with a rollback path.
- Keep service restarts and account downtime visible; do not silently restart or migrate an instance as part of a UI refresh.
- Record the actor, release, result, and recovery details without credentials in the audit log.
- Verify registration, account visibility, service health, and version after updating.

The current status is tracked in [issue #7](../../project/issues/07-validation.md) and the [ORM project plan](../../project/README.md).
