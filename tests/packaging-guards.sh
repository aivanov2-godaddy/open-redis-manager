#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'packaging guard tests must run as root.\n' >&2; exit 1; }

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../packaging" && pwd -P)/lib.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-packaging-guards.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

ORM_INSTANCE_ROOT="$test_root/metadata"
ORM_INSTANCE_DATA="$test_root/data"

reset_roots() {
    rm -rf -- "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"
    mkdir -m 0711 -- "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"
    chown root:root -- "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"
}

assert_status() {
    local expected="$1" actual
    set +e
    orm_instances_exist
    actual=$?
    set -e
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'expected orm_instances_exist status %s, received %s.\n' "$expected" "$actual" >&2
        exit 1
    fi
}

reset_roots
assert_status 1

touch "$ORM_INSTANCE_DATA/instance-marker"
assert_status 0

reset_roots
touch "$ORM_INSTANCE_ROOT/instance-marker"
assert_status 0

reset_roots
chmod 0755 "$ORM_INSTANCE_DATA"
assert_status 2

reset_roots
chown 65534:65534 "$ORM_INSTANCE_ROOT"
assert_status 2

reset_roots
rm -rf -- "$ORM_INSTANCE_DATA"
assert_status 2

reset_roots
rm -rf -- "$ORM_INSTANCE_ROOT"
ln -s "$test_root/missing" "$ORM_INSTANCE_ROOT"
assert_status 2

reset_roots
find() { return 1; }
assert_status 2
unset -f find

printf 'Packaging instance-root guard tests passed.\n'
