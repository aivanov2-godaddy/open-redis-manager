#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'release verification tests must run as root.\n' >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/packaging/lib.sh"
source "$repo_root/packaging/release-lib.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-release-test.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
key_dir="$test_root/trusted-keys"
private_key="$test_root/test-private.pem"
metadata="$test_root/release.metadata"
signature="$test_root/release.sig"
mkdir -m 0700 "$key_dir"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key" >/dev/null 2>&1
openssl pkey -in "$private_key" -pubout -out "$key_dir/test-release.pem"
chmod 0600 "$private_key"
chmod 0644 "$key_dir/test-release.pem"
orm_release_safe_root_directory "$key_dir" \
    || { printf 'root-owned private key directory was rejected.\n' >&2; exit 1; }
unsafe_parent="$test_root/writable-parent"
mkdir -p "$unsafe_parent/child"
chmod 0777 "$unsafe_parent"
chmod 0700 "$unsafe_parent/child"
if orm_release_safe_root_directory "$unsafe_parent/child"; then
    printf 'writable non-sticky trust-key ancestor was accepted.\n' >&2
    exit 1
fi
chmod 01777 "$unsafe_parent"
orm_release_safe_root_directory "$unsafe_parent/child" \
    || { printf 'root-owned sticky temporary parent was rejected.\n' >&2; exit 1; }

future_day="$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')"
future_expiry="$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
past_day="$(date -u -d '-2 days' '+%Y-%m-%dT%H:%M:%SZ')"
past_expiry="$(date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')"

[[ "$(orm_semver_compare '1.2.3-alpha.2' '1.2.3-alpha.10')" == -1 \
    && "$(orm_semver_compare '1.2.3-rc.1' '1.2.3')" == -1 \
    && "$(orm_semver_compare '1.2.3+build.1' '1.2.3+build.2')" == 0 ]] \
    || { printf 'SemVer comparison does not follow prerelease/build ordering.\n' >&2; exit 1; }

write_artifact() {
    local version="$1" release_root="$test_root/orm-$1" path
    artifact="$test_root/orm-${version}.tar.gz"
    rm -rf -- "$release_root"
    mkdir -p "$release_root"
    printf '%s\n' "$version" >"$release_root/VERSION"
    while IFS= read -r path; do
        [[ "$path" == VERSION ]] && continue
        mkdir -p "$release_root/$(dirname -- "$path")"
        cp -- "$repo_root/$path" "$release_root/$path"
        chmod 0644 "$release_root/$path"
    done <"$repo_root/packaging/release-required-files.txt"
    while IFS= read -r path; do
        [[ -d "$path" && ! -L "$path" ]] && chmod 0755 "$path"
    done < <(find "$release_root" -type d -print)
    chmod 0644 "$release_root/VERSION"
    if [[ ! -s "$release_root/packaging/release-required-files.txt" ]]; then
        printf 'release required-file manifest was not copied.\n' >&2
        exit 1
    fi
    tar -czf "$artifact" -C "$test_root" "orm-${version}"
}

write_metadata() {
    local version="${1:-0.2.0}" minimum="${2:-0.1.0-dev}" maximum="${3:-0.1.0-dev}"
    local created="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}" expires="${5:-$future_expiry}" key_id="${6:-test-release}"
    local size digest
    write_artifact "$version"
    size="$(stat -c '%s' -- "$artifact")"
    digest="$(sha256sum -- "$artifact" | awk '{print $1}')"
    {
        printf 'orm-release-metadata-v1\n'
        printf 'product|orm\nkey_id|%s\nversion|%s\nchannel|stable\n' "$key_id" "$version"
        printf 'artifact|orm-%s.tar.gz\nartifact_size|%s\nartifact_sha256|%s\n' "$version" "$size" "$digest"
        printf 'min_from_version|%s\nmax_from_version|%s\ncreated_at|%s\nexpires_at|%s\n' "$minimum" "$maximum" "$created" "$expires"
    } >"$metadata"
    openssl dgst -sha256 -sign "$private_key" -out "$signature" "$metadata"
}

expect_invalid() {
    local description="$1"
    if orm_release_metadata_verify "$metadata" "$signature" "$artifact" "$key_dir" '0.1.0-dev' >/dev/null 2>&1; then
        printf 'release verification accepted %s.\n' "$description" >&2
        exit 1
    fi
}

write_metadata
[[ "$(orm_release_verify_bundle "$metadata" "$signature" "$artifact" "$key_dir" '0.1.0-dev')" == 0.2.0 ]] \
    || { printf 'valid signed release was rejected.\n' >&2; exit 1; }

if (cd "$test_root" && orm_release_metadata_verify release.metadata release.sig "$artifact" "$key_dir" '0.1.0-dev' >/dev/null 2>&1); then
    printf 'relative release paths were accepted.\n' >&2
    exit 1
fi

printf 'tampered\n' >>"$artifact"
expect_invalid 'an artifact whose digest changed'

write_metadata
sed -i 's/^version|0\.2\.0$/version|0.2.1/' "$metadata"
expect_invalid 'metadata modified after signing'

write_metadata 0.2.0 0.1.0-dev 0.1.0-dev "$past_day" "$past_expiry"
expect_invalid 'expired metadata'

write_metadata 0.2.0 0.2.0 0.3.0
expect_invalid 'an installed version outside the signed compatibility range'

write_metadata 0.1.0-dev
expect_invalid 'a non-upgrade or equal-version release'

write_metadata 0.2.0 0.1.0-dev 0.1.0-dev "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" "$future_expiry"
expect_invalid 'metadata issued too far in the future'

write_metadata 0.2.0 0.1.0-dev 0.1.0-dev "$future_day" "$future_expiry" unknown-key
expect_invalid 'a key id without a pinned public key'

write_metadata
sed -i 's/^key_id|test-release$/key_id|test-release\nkey_id|test-release/' "$metadata"
expect_invalid 'duplicate metadata fields'

printf 'Signed release metadata and artifact verification checks passed.\n'
