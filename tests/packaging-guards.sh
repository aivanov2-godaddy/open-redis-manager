#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'packaging guard tests must run as root.\n' >&2; exit 1; }

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../packaging" && pwd -P)/lib.sh"
grep -Fxq 'ReadWritePaths=/etc/orm-instances /var/lib/orm-instances -/var/lib/orm-events' "$ORM_PACKAGE_ROOT/systemd/orm-broker.service" || {
    printf 'broker writable paths must be limited to ORM instance and provider event state.\n' >&2
    exit 1
}
grep -Fxq 'ReadWritePaths=-/var/lib/orm-events' "$ORM_PACKAGE_ROOT/systemd/orm-provider-events.service" || {
    printf 'provider event delivery must tolerate an absent event storage directory on upgrades.\n' >&2
    exit 1
}
grep -Fxq 'Wants=orm-metrics-collect@%i.timer' "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" || {
    printf 'instance service must activate its account-scoped metrics timer.\n' >&2
    exit 1
}
grep -Fxq 'StartLimitIntervalSec=5min' "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" || {
    printf 'instance service must use an explicit restart-rate window.\n' >&2
    exit 1
}
grep -Fxq 'StartLimitBurst=5' "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" || {
    printf 'instance service must cap starts within its restart-rate window.\n' >&2
    exit 1
}
grep -Fxq 'Restart=on-failure' "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" || {
    printf 'instance service must restart failures but not intentional stops.\n' >&2
    exit 1
}
grep -Fxq 'RestartSec=10s' "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" || {
    printf 'instance service must use the documented retry delay.\n' >&2
    exit 1
}
grep -Fxq 'User=%i' "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.service" || {
    printf 'metrics collection must run as its cPanel account.\n' >&2
    exit 1
}
grep -Fxq 'RestrictAddressFamilies=AF_UNIX' "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.service" || {
    printf 'metrics collection must use only Unix-domain sockets.\n' >&2
    exit 1
}
grep -Fxq 'OnCalendar=hourly' "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.timer" || {
    printf 'metrics history must use a bounded hourly schedule.\n' >&2
    exit 1
}
grep -Fq 'metrics_timer "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.timer" "$ORM_METRICS_TIMER" 644' "$ORM_PACKAGE_ROOT/lib.sh" || {
    printf 'installer tracking must include the hourly metrics timer.\n' >&2
    exit 1
}
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-packaging-guards.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

# The release updater checks that the broker retains its pre-update state and,
# when active, still exposes the correctly owned runtime socket.
health_root="$test_root/broker-health"
mkdir -m 0700 "$health_root" "$health_root/bin"
cat >"$health_root/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -e
case "$1 $2" in
    'is-enabled orm-broker.service') printf '%s\n' "${TEST_BROKER_ENABLED:-enabled}" ;;
    'is-active orm-broker.service') printf '%s\n' "${TEST_BROKER_ACTIVE:-inactive}" ;;
    *) exit 1 ;;
esac
SH
chmod 0755 "$health_root/bin/systemctl"
ORM_SYSTEMCTL="$health_root/bin/systemctl"
ORM_BROKER_SOCKET="$health_root/run/orm/broker.sock"
mkdir -p "$(dirname -- "$ORM_BROKER_SOCKET")"
chmod 0755 "$health_root/run" "$(dirname -- "$ORM_BROKER_SOCKET")"
export TEST_BROKER_ENABLED=enabled TEST_BROKER_ACTIVE=active
orm_capture_broker_state
if orm_broker_health_matches_initial; then
    printf 'active broker health accepted a missing socket.\n' >&2
    exit 1
fi
"$ORM_PERL" -MSocket -e 'socket(my $socket, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!"; bind($socket, sockaddr_un($ARGV[0])) or die "bind: $!";' "$ORM_BROKER_SOCKET"
chmod 0666 "$ORM_BROKER_SOCKET"
orm_broker_health_matches_initial || {
    printf 'healthy active broker state and socket were rejected.\n' >&2
    exit 1
}
export TEST_BROKER_ACTIVE=inactive
if orm_broker_health_matches_initial; then
    printf 'broker active-state drift was accepted.\n' >&2
    exit 1
fi
export TEST_BROKER_ACTIVE=active TEST_BROKER_ENABLED=disabled
if orm_broker_health_matches_initial; then
    printf 'broker enabled-state drift was accepted.\n' >&2
    exit 1
fi
export TEST_BROKER_ACTIVE=inactive TEST_BROKER_ENABLED=disabled
orm_capture_broker_state
orm_broker_health_matches_initial || {
    printf 'a deliberately inactive and disabled broker state was not preserved.\n' >&2
    exit 1
}
export TEST_BROKER_ACTIVE=activating
if orm_capture_broker_state; then
    printf 'an unknown transitional broker state was accepted.\n' >&2
    exit 1
fi
export TEST_BROKER_ACTIVE=failed
orm_capture_broker_state
if orm_broker_health_matches_initial; then
    printf 'a failed broker service was accepted as healthy.\n' >&2
    exit 1
fi

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
mkdir -m 0711 "$ORM_INSTANCE_DATA/.orm-backups"
mkdir -m 0750 "$ORM_INSTANCE_DATA/.orm-backups/demo"
touch "$ORM_INSTANCE_DATA/.orm-backups/demo/snapshot-marker.rdb"
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

mock_enabled_state=disabled
mock_active_state=failed
orm_capture_broker_state
orm_test_systemctl disable --now orm-broker.service
orm_broker_state_matches_initial || {
    printf 'failed broker state was not treated as non-active.\n' >&2
    exit 1
}
orm_restore_broker_state
[[ "$mock_enabled_state" == disabled && "$mock_active_state" == inactive ]] || {
    printf 'rollback unexpectedly started a previously failed broker.\n' >&2
    exit 1
}

printf 'Packaging instance-root guard tests passed.\n'
