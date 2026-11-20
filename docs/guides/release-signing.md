# Offline release bundle signing

`packaging/build-release.sh` builds a release bundle from a clean Git checkout and signs the strict metadata format consumed by the WHM updater. Signed metadata records the exact 40- or 64-character Git source commit; WHM displays it beside the version, key ID, and artifact digest. The declaration binds the signer’s approval to a specific commit, but does not by itself prove reproducible-build equivalence or that the commit was reviewed. Verify that it is the intended merged commit before signing. The private key stays outside the repository and is never copied to the output. This is an offline operator workflow, not a hosted signing service or automatic release publisher.

## Prepare a release source

1. Review and merge the release changes through pull requests.
2. Set the tracked `VERSION` file to the exact release version and commit it.
3. Check out that commit with no modified or untracked files. The builder refuses a dirty checkout or a requested version that differs from `VERSION`.
4. Keep the RSA private signing key on an offline or tightly controlled release workstation. Use a key of at least 3072 bits, file mode `0600`, and a location outside the repository. Do not place it on a cPanel server, in CI logs, or in a public artifact directory.
5. Create an output directory outside the checkout that is not group/world writable.

## Build and sign

The builder prompts for an encrypted key's passphrase through OpenSSL. Keep the passphrase out of command arguments and shell history.

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -aes-256-cbc -out /secure/offline/orm-release-2026.pem
chmod 0600 /secure/offline/orm-release-2026.pem
mkdir -m 0700 /secure/release-output

bash packaging/build-release.sh \
  0.2.0 stable orm-release-2026 \
  0.1.0-dev 0.1.0 \
  /secure/offline/orm-release-2026.pem \
  /secure/release-output 30
```

The builder requires the candidate release to be newer than the maximum installed version. The compatibility range is inclusive. Metadata validity is limited to 1–90 days, defaults to 30, and must still be valid when an administrator applies the update. Stable versions cannot include a prerelease suffix. Preview versions may.

The command creates a new `orm-VERSION/` directory containing:

- `orm-VERSION.tar.gz` — the allowlisted release payload, with normalized file ownership, timestamps and modes;
- `release.metadata` — version, compatibility range, channel, key ID, exact source commit, artifact size/digest, validity window, and the signed `state_migrations|none` declaration;
- `release.sig` — an RSA/SHA-256 detached signature over the exact metadata bytes;
- `KEY_ID.pem` — the derived public key to distribute through a separately reviewed trust-key change.

It validates the archive structure and checks the signature against the derived public key before publishing the output directory atomically. Existing output for the same version is never overwritten. The tool does not upload, publish, install, or stage files on a server.

The updater accepts only the no-migration declaration. Releases that need to alter persistent ORM state must wait for a separately reviewed, versioned migration path with backup, rollback, and interruption recovery. See the [reviewed no-migration release contract](update-lifecycle.md#reviewed-no-migration-release-contract).

## Signing-key custody and rotation

The repository contains no production signing private key. Before the first public release, the project owner must designate the release-key custodian and approve the trust-key distribution channel. Keep the encrypted RSA private key on an offline or tightly controlled release workstation, restrict access to the designated custodian, and maintain an encrypted backup with separately controlled access. Never place the private key or passphrase in Git, CI, Ruflo memory, a cPanel host, a public artifact, or command-line arguments. This repository does not operate a signing service or automate key revocation.

For a planned rotation:

1. Generate a new encrypted key and a never-before-used key ID. Derive the public key and record its SHA-256 fingerprint through the offline release procedure.
2. Distribute the new public key to target servers through the owner-approved administrative channel as `/etc/orm/release-keys/KEY_ID.pem`, root-owned and not writable by group or other users. Verify its fingerprint on each target.
3. Keep the old public key installed during an overlap period. Sign new bundles with the new key ID only after the trust change is deployed. Do not remove the old key while any unexpired bundle or queued update may rely on it.
4. After the old key’s latest metadata expiry (at most 90 days), confirm no staged or queued release uses it, then remove its public key from targets through the same reviewed channel. Never reuse a retired key ID.

For suspected compromise, stop signing immediately, remove the compromised public key from every target through a trusted administrative channel, and establish a new key and trust change before resuming. A GitHub commit or artifact signature cannot revoke a key already trusted by an offline server.

## Publish and stage a bundle

The offline builder creates and verifies files but does not publish them. Before publication, verify the signed source commit is the reviewed release commit, confirm the clean checkout and green CI, inspect `release.metadata`, compare the artifact digest, verify the detached signature, and retain the complete bundle with its public key and a release record. If publishing through GitHub Releases, attach the archive, metadata, signature, and public key as a single reviewed release; publish the SHA-256 digest and source commit in the release notes. Do not overwrite a published version or silently replace its artifacts. ORM does not publish release artifacts automatically.

Transfer the archive as `release.tar.gz`, `release.metadata`, and `release.sig` to `/var/cpanel/orm/updates/staged/` using the owner-approved administrative channel. Keep that directory root-owned with mode `0700`; staged files must be regular files, root-owned, and not group/world writable. Never copy the private key to a server. Independently compare the staged archive digest to the published release record. Then use **WHM → Open Redis Manager → Verify staged release**, confirm the source commit, key ID, digest, state-migration declaration and file actions, and apply only a conflict-free preview after explicit confirmation.

See the [update preview guide](update-preview.md), [transaction lifecycle](update-lifecycle.md), and [recovery guide](update-recovery.md). Live cPanel validation of signing, staging, apply, rollback, and recovery is still required before production use.
