#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'release build integration tests must run as root.\n' >&2; exit 1; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-release-build-test.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
source_root="$test_root/source"
output_root="$test_root/output"
private_key="$test_root/release-private.pem"
trusted_key_root="$test_root/trusted-keys"
mkdir -m 0700 -- "$source_root" "$output_root" "$trusted_key_root"

tar --exclude=.git -cf - -C "$repo_root" . | tar -xf - -C "$source_root"
git -C "$source_root" init -q
git -C "$source_root" config user.name 'ORM release fixture'
git -C "$source_root" config user.email 'orm-release-fixture@example.invalid'
git -C "$source_root" config commit.gpgsign false
git -C "$source_root" add -A
git -C "$source_root" commit -q -m 'Create clean release fixture'
printf '0.2.0\n' >"$source_root/VERSION"
git -C "$source_root" add VERSION
git -C "$source_root" commit -q -m 'Set fixture release version'

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key" >/dev/null 2>&1
chmod 0600 -- "$private_key"
bash "$source_root/packaging/build-release.sh" \
    0.2.0 stable orm-test 0.1.0-dev 0.1.0-dev "$private_key" "$output_root" 30

bundle="$output_root/orm-0.2.0"
[[ -d "$bundle" && ! -L "$bundle" ]] || { printf 'release bundle directory was not published.\n' >&2; exit 1; }
[[ -f "$bundle/orm-0.2.0.tar.gz" && -f "$bundle/release.metadata" \
    && -f "$bundle/release.sig" && -f "$bundle/orm-test.pem" ]] \
    || { printf 'release bundle is missing a required artifact.\n' >&2; exit 1; }
[[ ! -e "$bundle/release-private.pem" ]] || { printf 'private signing key was copied into the bundle.\n' >&2; exit 1; }
grep -R -q -- 'BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY' "$bundle" \
    && { printf 'private signing key material was found in the bundle.\n' >&2; exit 1; }

install -m 0644 -- "$bundle/orm-test.pem" "$trusted_key_root/orm-test.pem"
source "$source_root/packaging/release-lib.sh"
source "$source_root/packaging/lib.sh"
ORM_PACKAGE_ROOT="$source_root/packaging"
ORM_PERL="$(command -v perl)"
verified_version="$(orm_release_verify_bundle \
    "$bundle/release.metadata" "$bundle/release.sig" "$bundle/orm-0.2.0.tar.gz" \
    "$trusted_key_root" 0.1.0-dev)"
[[ "$verified_version" == 0.2.0 ]] || { printf 'built bundle failed the installed release verifier.\n' >&2; exit 1; }

if bash "$source_root/packaging/build-release.sh" \
    0.2.0 stable orm-test 0.1.0-dev 0.1.0-dev "$private_key" "$output_root" 30 >/dev/null 2>&1; then
    printf 'release builder overwrote an existing output bundle.\n' >&2
    exit 1
fi
if bash "$source_root/packaging/build-release.sh" \
    0.2.0 stable orm-test 0.1.0-dev 0.1.0-dev "$private_key" "$source_root" 30 >/dev/null 2>&1; then
    printf 'release builder accepted an output directory inside the source repository.\n' >&2
    exit 1
fi
printf 'Offline signed release build checks passed.\n'
