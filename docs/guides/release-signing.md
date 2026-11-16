# Offline release bundle signing

`packaging/build-release.sh` builds a release bundle from a clean Git checkout and signs the strict metadata format consumed by the WHM updater. The private key stays outside the repository and is never copied to the output. This is an offline operator workflow, not a hosted signing service or automatic release publisher.

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
- `release.metadata` — version, compatibility range, channel, key ID, artifact size/digest, and validity window;
- `release.sig` — an RSA/SHA-256 detached signature over the exact metadata bytes;
- `KEY_ID.pem` — the derived public key to distribute through a separately reviewed trust-key change.

It validates the archive structure and checks the signature against the derived public key before publishing the output directory atomically. Existing output for the same version is never overwritten. The tool does not upload, publish, install, or stage files on a server.

## Trust and stage the bundle

Review the generated metadata, artifact digest, signature, archive, and public key. Distribute the public key to the target server through a trusted administrative channel and install it as `/etc/orm/release-keys/KEY_ID.pem`, owned by root with no group/world write access. Keep currently trusted keys until all releases signed by them have expired or been deliberately retired. Plan key rotation before signing with a new key ID.

Manually stage the three release files under the fixed root-owned directory `/var/cpanel/orm/updates/staged/` as `release.metadata`, `release.sig`, and `release.tar.gz`. Never copy the private key to the server. Then use **WHM → Open Redis Manager → Verify staged release**, review the file actions, and apply only a conflict-free preview after explicit confirmation.

See the [update preview guide](update-preview.md), [transaction lifecycle](update-lifecycle.md), and [recovery guide](update-recovery.md). Live cPanel validation of signing, staging, apply, rollback, and recovery is still required before production use.
