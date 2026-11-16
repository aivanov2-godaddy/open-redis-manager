# WHM signed update preview

The WHM page exposes a root-only **Verify staged release** action. It is read-only: it checks a manually staged signed release and displays its installed and candidate versions, signature key ID, artifact digest, and managed-file actions. The preview never applies files, restarts services, or downloads an update.

![ORM WHM signed update preview interface](../../screenshots/whm-update-preview.png)

## Fixed paths

The preview uses only these root-owned paths:

| Purpose | Path |
|---|---|
| Release metadata | `/var/cpanel/orm/updates/staged/release.metadata` |
| Detached signature | `/var/cpanel/orm/updates/staged/release.sig` |
| Release archive | `/var/cpanel/orm/updates/staged/release.tar.gz` |
| Pinned public keys | `/etc/orm/release-keys/` |
| Installed file manifest | `/usr/local/cpanel/3rdparty/orm/install-manifest` |

Create the staging and key directories with mode `0700`, owned by root. Store a public key as `<key_id>.pem` where `<key_id>` matches the signed metadata. Never put a private signing key on the cPanel server or in this repository. The verifier rejects unsafe ownership, permissions, symlinks, malformed metadata, expired or incompatible releases, invalid signatures, and archives that do not match the signed install map.

The root operator stages the bundle files using the fixed names above, then submits the preview form through the authenticated `/cpsess` WHM session. The tool runs `/usr/bin/bash` with a fixed argument list under a 30-second timeout; stderr is discarded and untrusted file paths cannot be supplied by the browser. Missing or invalid staging is reported without exposing raw process output.

## Current boundaries

- No remote update feed or automatic downloader is configured.
- The WHM page has no apply control. The separately documented root-only CLI transaction remains a command-line operation and still requires disposable-host validation.
- The preview is supported only for an installed schema v3 manifest. Adopt older manifests only through the exact-current-package adoption procedure in the [update lifecycle guide](update-lifecycle.md).
- This preview does not establish compatibility with every cPanel/WHM release or replace a complete install, rollback, recovery, and post-update validation gate.
