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

mock_enabled_state=enabled
mock_active_state=active
orm_test_systemctl() {
    case "${1:-}" in
        is-enabled) printf '%s\n' "$mock_enabled_state" ;;
        is-active) printf '%s\n' "$mock_active_state" ;;
        disable)
            mock_enabled_state=disabled
            if [[ "${2:-}" == --now ]]; then mock_active_state=inactive; fi
            ;;
        enable) mock_enabled_state=enabled ;;
        start) mock_active_state=active ;;
        stop) mock_active_state=inactive ;;
        *) return 1 ;;
    esac
}
ORM_SYSTEMCTL=orm_test_systemctl
orm_capture_broker_state
orm_test_systemctl disable --now orm-broker.service
if orm_broker_state_matches_initial; then
    printf 'expected broker state change after disable --now.\n' >&2
    exit 1
fi
orm_restore_broker_state
orm_broker_state_matches_initial || {
    printf 'enabled and active broker state was not restored.\n' >&2
    exit 1
}

mock_enabled_state=disabled
mock_active_state=inactive
orm_capture_broker_state
orm_test_systemctl disable --now orm-broker.service
orm_broker_state_matches_initial || {
    printf 'disabled and inactive broker state unexpectedly changed.\n' >&2
    exit 1
}
orm_restore_broker_state
[[ "$mock_enabled_state" == disabled && "$mock_active_state" == inactive ]] || {
    printf 'rollback changed a broker that was initially disabled and inactive.\n' >&2
    exit 1
}

printf 'Packaging instance-root guard tests passed.\n'
