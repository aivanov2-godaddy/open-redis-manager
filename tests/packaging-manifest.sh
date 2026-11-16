#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'packaging manifest tests must run as root.\n' >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/packaging/lib.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-manifest-test.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

if orm_safe_target_parent_chain 'relative/file' || orm_safe_target_parent_chain "$test_root/../source"; then
    printf 'unsafe relative or traversal path passed the parent-chain check.\n' >&2
    exit 1
fi

ORM_VERSION_FILE="$test_root/VERSION"
ORM_INSTALL_MANIFEST="$test_root/install-manifest"
printf '0.1.0-rc.2+test.1\n' >"$ORM_VERSION_FILE"
printf 'package payload\n' >"$test_root/source"
install -m 0644 "$test_root/source" "$test_root/target"

orm_package_file_map() {
    printf 'test_payload|%s|%s|644\n' "$test_root/source" "$test_root/target"
}

orm_write_install_manifest "$ORM_INSTALL_MANIFEST"
[[ "$(head -n 1 "$ORM_INSTALL_MANIFEST")" == orm-install-manifest-v3 ]] \
    || { printf 'writer did not create a v3 manifest.\n' >&2; exit 1; }
[[ "$(orm_install_manifest_version "$ORM_INSTALL_MANIFEST")" == '0.1.0-rc.2+test.1' ]] \
    || { printf 'v3 manifest version was not readable.\n' >&2; exit 1; }
orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
    || { printf 'valid v3 manifest did not validate.\n' >&2; exit 1; }

{ printf 'orm-install-manifest-v2\nversion|0.1.0-rc.2+test.1\n'; tail -n +3 "$ORM_INSTALL_MANIFEST" | cut -d '|' -f 1-3; } >"$test_root/v2-manifest"
chmod 0600 "$test_root/v2-manifest"
chown root:root "$test_root/v2-manifest"
orm_validate_install_manifest "$test_root/v2-manifest" \
    || { printf 'compatible v2 manifest was rejected.\n' >&2; exit 1; }

{ printf 'orm-install-manifest-v1\n'; tail -n +3 "$ORM_INSTALL_MANIFEST" | cut -d '|' -f 1-3; } >"$test_root/legacy.tmp"
chmod 0600 "$test_root/legacy.tmp"
chown root:root "$test_root/legacy.tmp"
mv -- "$test_root/legacy.tmp" "$test_root/legacy-manifest"
orm_validate_install_manifest "$test_root/legacy-manifest" \
    || { printf 'compatible v1 manifest was rejected.\n' >&2; exit 1; }
[[ -z "$(orm_install_manifest_version "$test_root/legacy-manifest")" ]] \
    || { printf 'v1 manifest unexpectedly claimed a version.\n' >&2; exit 1; }

orm_adopt_current_install_manifest "$test_root/legacy-manifest" \
    || { printf 'an exact current v1 manifest could not be safely adopted.\n' >&2; exit 1; }
[[ "$(head -n 1 "$test_root/legacy-manifest")" == orm-install-manifest-v3 \
    && "$(orm_install_manifest_version "$test_root/legacy-manifest")" == '0.1.0-rc.2+test.1' ]] \
    || { printf 'v1 adoption did not write the current v3 package version.\n' >&2; exit 1; }
orm_validate_install_manifest "$test_root/legacy-manifest" \
    || { printf 'adopted v1 manifest did not validate.\n' >&2; exit 1; }

{ printf 'orm-install-manifest-v2\nversion|0.1.0-rc.2+test.1\n'; tail -n +3 "$ORM_INSTALL_MANIFEST" | cut -d '|' -f 1-3; } \
    >"$test_root/v2-current-manifest"
chmod 0600 "$test_root/v2-current-manifest"
chown root:root "$test_root/v2-current-manifest"
orm_adopt_current_install_manifest "$test_root/v2-current-manifest" \
    || { printf 'an exact current v2 manifest could not be safely adopted.\n' >&2; exit 1; }
[[ "$(head -n 1 "$test_root/v2-current-manifest")" == orm-install-manifest-v3 ]] \
    || { printf 'v2 adoption did not write a v3 manifest.\n' >&2; exit 1; }

{ printf 'orm-install-manifest-v2\nversion|0.0.1\n'; tail -n +3 "$ORM_INSTALL_MANIFEST" | cut -d '|' -f 1-3; } \
    >"$test_root/v2-old-manifest"
chmod 0600 "$test_root/v2-old-manifest"
chown root:root "$test_root/v2-old-manifest"
old_manifest_digest="$(sha256sum "$test_root/v2-old-manifest" | awk '{print $1}')"
if orm_adopt_current_install_manifest "$test_root/v2-old-manifest"; then
    printf 'v2 manifest with a different package version was adopted.\n' >&2
    exit 1
fi
[[ "$(sha256sum "$test_root/v2-old-manifest" | awk '{print $1}')" == "$old_manifest_digest" ]] \
    || { printf 'rejected v2 adoption changed the original manifest.\n' >&2; exit 1; }

printf 'modified package payload\n' >"$test_root/target"
modified_target_digest="$(sha256sum "$test_root/target" | awk '{print $1}')"
printf 'orm-install-manifest-v1\ntest_payload|644|%s\n' "$modified_target_digest" >"$test_root/v1-stale-manifest"
chmod 0600 "$test_root/v1-stale-manifest"
chown root:root "$test_root/v1-stale-manifest"
orm_validate_install_manifest "$test_root/v1-stale-manifest" \
    || { printf 'tampered v1 fixture did not match its installed payload.\n' >&2; exit 1; }
stale_manifest_digest="$(sha256sum "$test_root/v1-stale-manifest" | awk '{print $1}')"
if orm_adopt_current_install_manifest "$test_root/v1-stale-manifest"; then
    printf 'v1 manifest matching tampered installed content was adopted.\n' >&2
    exit 1
fi
[[ "$(sha256sum "$test_root/v1-stale-manifest" | awk '{print $1}')" == "$stale_manifest_digest" ]] \
    || { printf 'rejected v1 adoption changed the original manifest.\n' >&2; exit 1; }
printf 'package payload\n' >"$test_root/target"
chmod 0644 "$test_root/target"

for invalid in '01.2.3' '1.2' '1.2.3-' '1.2.3-rc.02' '1.2.3-alpha..1' '1.2.3+bad value' '1.2.3\n2.0.0'; do
    printf '%b\n' "$invalid" >"$ORM_VERSION_FILE"
    if orm_read_package_version >/dev/null 2>&1; then
        printf 'invalid package version was accepted: %s\n' "$invalid" >&2
        exit 1
    fi
done

{ printf 'orm-install-manifest-v2\nversion|not-semver\n'; tail -n +3 "$ORM_INSTALL_MANIFEST" | cut -d '|' -f 1-3; } >"$test_root/invalid-version.tmp"
chmod 0600 "$test_root/invalid-version.tmp"
chown root:root "$test_root/invalid-version.tmp"
mv -- "$test_root/invalid-version.tmp" "$test_root/invalid-version-manifest"
if orm_validate_install_manifest "$test_root/invalid-version-manifest"; then
    printf 'invalid version in v2 manifest was accepted.\n' >&2
    exit 1
fi

cp -- "$ORM_INSTALL_MANIFEST" "$test_root/invalid-target-manifest"
chmod 0600 "$test_root/invalid-target-manifest"
chown root:root "$test_root/invalid-target-manifest"
sed -i "s#|${test_root}/target\$#|${test_root}/other-target#" "$test_root/invalid-target-manifest"
if orm_validate_install_manifest "$test_root/invalid-target-manifest"; then
    printf 'a v3 manifest with a changed install target was accepted.\n' >&2
    exit 1
fi

printf 'Versioned package manifest compatibility checks passed.\n'
