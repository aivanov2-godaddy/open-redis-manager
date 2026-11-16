#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'packaging upgrade tests must run as root.\n' >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/packaging/lib.sh"
BASE_PATH="$PATH"
BASE_TMPDIR=''
for candidate in "${TMPDIR:-/tmp}" /var/tmp /run /root; do
    [[ -d "$candidate" && -w "$candidate" && ! -L "$candidate" ]] || continue
    probe="$(mktemp "$candidate/.orm-exec-probe.XXXXXXXX")" || continue
    printf '#!/usr/bin/env bash\nexit 0\n' >"$probe"
    chmod 0700 "$probe"
    if "$probe" >/dev/null 2>&1; then BASE_TMPDIR="$candidate"; fi
    rm -f -- "$probe"
    [[ -n "$BASE_TMPDIR" ]] && break
done
[[ -n "$BASE_TMPDIR" ]] || { printf 'packaging tests require a writable executable temporary filesystem.\n' >&2; exit 1; }
fixture_root="$repo_root/tests/fixtures/orm-identity-v1-install"
REAL_INSTALL="$(command -v install)"
REAL_CP="$(command -v cp)"
test_root=''
active_socket_pid=''
cleanup_test_root() {
    if [[ -n "$test_root" && -f "$test_root/socket.pid" ]]; then kill "$(cat "$test_root/socket.pid")" 2>/dev/null || true; fi
    if [[ -n "$test_root" && -f "$test_root/initial-socket.pid" ]]; then kill "$(cat "$test_root/initial-socket.pid")" 2>/dev/null || true; fi
    if [[ -n "$active_socket_pid" ]]; then kill "$active_socket_pid" 2>/dev/null || true; fi
    if [[ -n "$test_root" ]]; then rm -rf -- "$test_root"; fi
}
trap cleanup_test_root EXIT

prepare_case() {
    local case_name="$1" initial_enabled="${2:-enabled}" initial_active="${3:-active}" key target mode
    test_root="$(mktemp -d "$BASE_TMPDIR/orm-upgrade-${case_name}.XXXXXXXX")"
    trap cleanup_test_root EXIT
    active_socket_pid=''
    export TEST_ROOT="$test_root"
    export TEST_LOG="$test_root/lifecycle.log"
    export TEST_SOCKET="$test_root/run/orm/broker.sock"
    export TEST_CPANEL_MARKER="$test_root/cpanel-plugin-installed"
    export TEST_APPCONFIG_STATE="$test_root/appconfig-registered"
    export TEST_SYSTEMCTL_STATE="$test_root/systemctl-state"
    export TEST_REAL_INSTALL="$REAL_INSTALL"
    export TEST_REAL_CP="$REAL_CP"
    export TEST_CURRENT_FEATURE_SHA="$(sha256sum "$ORM_PACKAGE_ROOT/cpanel/icons/orm-feature.svg" | awk '{print $1}')"
    export TEST_LEGACY_FEATURE_SHA="$(sha256sum "$ORM_PACKAGE_ROOT/legacy/identity-v1/cpanel/icons/orm-feature.svg" | awk '{print $1}')"
    export TMPDIR="$test_root/tmp"
    export PATH="$test_root/bin:$BASE_PATH"
    mkdir -p "$test_root/bin" "$test_root/cpanel/php" "$test_root/cpanel/scripts" \
        "$test_root/cpanel/bin" "$test_root/var/cpanel/apps" "$test_root/run/orm" "$TMPDIR"
    chmod 0755 "$test_root/run/orm"
    : >"$test_root/cpanel/php/WHM.php"
    : >"$test_root/cpanel/php/cpanel.php"
    cat >"$test_root/bin/install_plugin" <<'MOCK'
#!/usr/bin/env bash
printf 'install_plugin %s\n' "$*" >>"$TEST_LOG"
feature_sha="$(tar -xOzf "$1" orm-feature.svg | sha256sum | awk '{print $1}')"
if [[ "$feature_sha" == "$TEST_CURRENT_FEATURE_SHA" ]]; then
    plugin_state=current
elif [[ "$feature_sha" == "$TEST_LEGACY_FEATURE_SHA" ]]; then
    plugin_state=legacy
else
    exit 48
fi
if [[ "$plugin_state" == current && "${TEST_FAIL_CURRENT_PLUGIN_ONCE:-0}" == 1 && ! -e "$TEST_ROOT/plugin-failure-used" ]]; then
    : >"$TEST_ROOT/plugin-failure-used"
    exit 43
fi
printf '%s\n' "$plugin_state" >"$TEST_CPANEL_MARKER"
MOCK
    cat >"$test_root/bin/uninstall_plugin" <<'MOCK'
#!/usr/bin/env bash
printf 'uninstall_plugin %s\n' "$*" >>"$TEST_LOG"
feature_sha="$(tar -xOzf "$1" orm-feature.svg | sha256sum | awk '{print $1}')"
[[ "$feature_sha" == "$TEST_CURRENT_FEATURE_SHA" ]] || exit 49
rm -f -- "$TEST_CPANEL_MARKER"
if [[ "${TEST_FAIL_UNINSTALL_PLUGIN_ONCE:-0}" == 1 && ! -e "$TEST_ROOT/uninstall-plugin-failure-used" ]]; then
    : >"$TEST_ROOT/uninstall-plugin-failure-used"
    exit 43
fi
MOCK
    cat >"$test_root/bin/register_appconfig" <<'MOCK'
#!/usr/bin/env bash
printf 'register_appconfig %s\n' "$*" >>"$TEST_LOG"
cp -- "$1" "$ORM_APPCONFIG"
chmod 0600 "$ORM_APPCONFIG"
printf '1\n' >"$TEST_APPCONFIG_STATE"
MOCK
    cat >"$test_root/bin/unregister_appconfig" <<'MOCK'
#!/usr/bin/env bash
printf 'unregister_appconfig %s\n' "$*" >>"$TEST_LOG"
printf '0\n' >"$TEST_APPCONFIG_STATE"
rm -f -- "$ORM_APPCONFIG"
if [[ "${TEST_FAIL_UNREGISTER_ONCE:-0}" == 1 && ! -e "$TEST_ROOT/unregister-failure-used" ]]; then
    : >"$TEST_ROOT/unregister-failure-used"
    exit 43
fi
MOCK
    cat >"$test_root/bin/is_registered_with_appconfig" <<'MOCK'
#!/usr/bin/env bash
[[ "${TEST_FAIL_REGISTRATION_CHECK:-0}" == 1 ]] && exit 47
cat "$TEST_APPCONFIG_STATE"
MOCK
    cat >"$test_root/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -e
enabled_file="$TEST_SYSTEMCTL_STATE.enabled"
active_file="$TEST_SYSTEMCTL_STATE.active"
case "${1:-}" in
    is-enabled) cat "$enabled_file" ;;
    is-active) cat "$active_file" ;;
    enable) printf 'enabled\n' >"$enabled_file" ;;
    disable)
        printf 'disabled\n' >"$enabled_file"
        if [[ "${2:-}" == --now ]]; then
            printf 'inactive\n' >"$active_file"
            if [[ -f "$TEST_ROOT/socket.pid" ]]; then kill "$(cat "$TEST_ROOT/socket.pid")" 2>/dev/null || true; rm -f -- "$TEST_ROOT/socket.pid"; fi
            if [[ -f "$TEST_ROOT/initial-socket.pid" ]]; then kill "$(cat "$TEST_ROOT/initial-socket.pid")" 2>/dev/null || true; rm -f -- "$TEST_ROOT/initial-socket.pid"; fi
            rm -f -- "$TEST_SOCKET"
        fi
        ;;
    show) printf '4242\n' ;;
    daemon-reload)
        printf 'daemon-reload\n' >>"$TEST_LOG"
        if [[ "${TEST_FAIL_RELOAD_ONCE:-0}" == 1 && ! -e "$TEST_ROOT/reload-failure-used" ]]; then
            : >"$TEST_ROOT/reload-failure-used"
            exit 44
        fi
        ;;
    stop)
        printf 'stop\n' >>"$TEST_LOG"
        [[ ! -e "$TEST_ROOT/busy-connection" ]] || exit 51
        printf 'inactive\n' >"$active_file"
        if [[ -f "$TEST_ROOT/socket.pid" ]]; then
            kill "$(cat "$TEST_ROOT/socket.pid")" 2>/dev/null || true
            rm -f -- "$TEST_ROOT/socket.pid"
        fi
        if [[ -f "$TEST_ROOT/initial-socket.pid" ]]; then
            kill "$(cat "$TEST_ROOT/initial-socket.pid")" 2>/dev/null || true
            rm -f -- "$TEST_ROOT/initial-socket.pid"
        fi
        rm -f -- "$TEST_SOCKET"
        ;;
    start)
        printf 'start\n' >>"$TEST_LOG"
        if [[ "${TEST_FAIL_START_ONCE:-0}" == 1 && ! -e "$TEST_ROOT/start-failure-used" ]]; then
            : >"$TEST_ROOT/start-failure-used"
            printf 'failed\n' >"$active_file"
            exit 45
        fi
        perl -MIO::Socket::UNIX -MSocket=SOCK_STREAM -e '$s=IO::Socket::UNIX->new(Type=>SOCK_STREAM,Local=>$ARGV[0],Listen=>64) or die $!; chmod 0666,$ARGV[0] or die $!; $SIG{TERM}=sub { close $s; exit }; sleep 3600' "$TEST_SOCKET" >/dev/null 2>&1 </dev/null &
        printf '%s\n' "$!" >"$TEST_ROOT/socket.pid"
        for attempt in {1..50}; do [[ -S "$TEST_SOCKET" ]] && break; sleep 0.02; done
        [[ -S "$TEST_SOCKET" ]]
        printf 'active\n' >"$active_file"
        ;;
    *) exit 2 ;;
esac
MOCK
    cat >"$test_root/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'state established'* ]]; then
    if [[ -e "$TEST_ROOT/busy-connection" ]]; then
        : >"$TEST_ROOT/busy-connection-observed"
        printf 'u_str ESTAB 0 0 %s users:(("perl",pid=4242,fd=4))\n' "$TEST_SOCKET"
    fi
    exit 0
fi
printf 'u_str LISTEN 0 64 %s users:(("perl",pid=4242,fd=3))\n' "$TEST_SOCKET"
MOCK
    cat >"$test_root/bin/install" <<'MOCK'
#!/usr/bin/env bash
if [[ "${TEST_FAIL_FILE_INSTALL_ONCE:-0}" == 1 && "${1:-}" == -m && "${3:-}" == *Server.pm && ! -e "$TEST_ROOT/file-failure-used" ]]; then
    : >"$TEST_ROOT/file-failure-used"
    exit 46
fi
exec "$TEST_REAL_INSTALL" "$@"
MOCK
    cat >"$test_root/bin/cp" <<'MOCK'
#!/usr/bin/env bash
if [[ "${TEST_FAIL_RESTORE_ONCE:-0}" == 1 && "${3:-}" == "$TEST_ROOT"/tmp/orm-upgrade.*/* && "${4:-}" == *'.orm-rollback.'* && ! -e "$TEST_ROOT/restore-failure-used" ]]; then
    : >"$TEST_ROOT/restore-failure-used"
    exit 50
fi
exec "$TEST_REAL_CP" "$@"
MOCK
    chmod 0755 "$test_root/bin/"*
    printf '%s\n' "$initial_enabled" >"$TEST_SYSTEMCTL_STATE.enabled"
    printf '%s\n' "$initial_active" >"$TEST_SYSTEMCTL_STATE.active"
    printf 'legacy\n' >"$TEST_CPANEL_MARKER"
    printf '1\n' >"$TEST_APPCONFIG_STATE"
    cp -- "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" "$test_root/var/cpanel/apps/open_redis_manager.conf"
    chmod 0600 "$test_root/var/cpanel/apps/open_redis_manager.conf"

    ORM_CPANEL_ROOT="$test_root/cpanel"
    ORM_INSTALL_PLUGIN="$test_root/bin/install_plugin"
    ORM_UNINSTALL_PLUGIN="$test_root/bin/uninstall_plugin"
    ORM_REGISTER_APPCONFIG="$test_root/bin/register_appconfig"
    ORM_UNREGISTER_APPCONFIG="$test_root/bin/unregister_appconfig"
    ORM_IS_REGISTERED="$test_root/bin/is_registered_with_appconfig"
    ORM_CPanel_LIVE="$ORM_CPANEL_ROOT/base/frontend/jupiter/orm"
    ORM_WHM_CGI="$ORM_CPANEL_ROOT/whostmgr/docroot/cgi"
    ORM_WHM_ICONS="$ORM_CPANEL_ROOT/whostmgr/docroot/addon_plugins"
    ORM_3RDPARTY="$ORM_CPANEL_ROOT/3rdparty/orm"
    ORM_INSTALL_MANIFEST="$ORM_3RDPARTY/install-manifest"
    ORM_APPCONFIG="$test_root/var/cpanel/apps/open_redis_manager.conf"
    ORM_LIFECYCLE_LOCK="$test_root/run/lock/orm-lifecycle.lock"
    ORM_SYSTEMCTL="$test_root/bin/systemctl"
    ORM_BROKER_BIN="$ORM_3RDPARTY/bin/orm-broker.pl"
    ORM_BROKER_LIB="$ORM_3RDPARTY/lib/Orm/Broker"
    ORM_BROKER_UNIT="$test_root/etc/systemd/system/orm-broker.service"
    ORM_INSTANCE_ROOT="$test_root/etc/orm-instances"
    ORM_INSTANCE_DATA="$test_root/var/lib/orm-instances"
    ORM_INSTANCE_UNIT="$test_root/etc/systemd/system/orm-instance@.service"
    ORM_INSTANCE_LAUNCHER="$ORM_3RDPARTY/bin/orm-instance-launcher"
    ORM_METRICS_COLLECTOR="$ORM_3RDPARTY/bin/orm-metrics-collect.pl"
    ORM_METRICS_SERVICE="$test_root/etc/systemd/system/orm-metrics-collect@.service"
    ORM_METRICS_TIMER="$test_root/etc/systemd/system/orm-metrics-collect@.timer"
    ORM_BROKER_SOCKET="$TEST_SOCKET"
    export ORM_CPANEL_ROOT ORM_INSTALL_PLUGIN ORM_UNINSTALL_PLUGIN ORM_REGISTER_APPCONFIG ORM_UNREGISTER_APPCONFIG
    export ORM_IS_REGISTERED ORM_CPanel_LIVE ORM_WHM_CGI ORM_WHM_ICONS ORM_3RDPARTY ORM_INSTALL_MANIFEST ORM_APPCONFIG
    export ORM_LIFECYCLE_LOCK ORM_SYSTEMCTL ORM_BROKER_BIN ORM_BROKER_LIB ORM_BROKER_UNIT ORM_INSTANCE_ROOT
    export ORM_INSTANCE_DATA ORM_INSTANCE_UNIT ORM_INSTANCE_LAUNCHER ORM_METRICS_COLLECTOR ORM_METRICS_SERVICE
    export ORM_METRICS_TIMER ORM_BROKER_SOCKET
    while IFS='|' read -r key target mode; do
        mkdir -p -- "$(dirname -- "$target")"
        install -m "$mode" "$fixture_root/$key" "$target"
    done < <(orm_legacy_identity_v1_file_map)
    export TEST_APPCONFIG_INODE="$(stat -c '%i' "$ORM_APPCONFIG")"
    if [[ "$initial_active" == active ]]; then
        perl -MIO::Socket::UNIX -MSocket=SOCK_STREAM -e '$s=IO::Socket::UNIX->new(Type=>SOCK_STREAM,Local=>$ARGV[0],Listen=>64) or die $!; chmod 0666,$ARGV[0] or die $!; sleep 3600' "$TEST_SOCKET" >/dev/null 2>&1 </dev/null &
        active_socket_pid=$!
        printf '%s\n' "$active_socket_pid" >"$test_root/initial-socket.pid"
        for attempt in {1..50}; do [[ -S "$TEST_SOCKET" ]] && break; sleep 0.02; done
        [[ -S "$TEST_SOCKET" ]] || { printf 'test broker socket could not be created.\n' >&2; exit 1; }
    fi

    runner="$test_root/upgrade-test.sh"
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf 'source %q\n' "$ORM_PACKAGE_ROOT/lib.sh"
        printf 'ORM_CPANEL_ROOT=%q\n' "$ORM_CPANEL_ROOT"
        printf 'ORM_INSTALL_PLUGIN=%q\nORM_UNINSTALL_PLUGIN=%q\n' "$ORM_INSTALL_PLUGIN" "$ORM_UNINSTALL_PLUGIN"
        printf 'ORM_REGISTER_APPCONFIG=%q\nORM_UNREGISTER_APPCONFIG=%q\nORM_IS_REGISTERED=%q\n' "$ORM_REGISTER_APPCONFIG" "$ORM_UNREGISTER_APPCONFIG" "$ORM_IS_REGISTERED"
        printf 'ORM_CPanel_LIVE=%q\nORM_WHM_CGI=%q\nORM_WHM_ICONS=%q\n' "$ORM_CPanel_LIVE" "$ORM_WHM_CGI" "$ORM_WHM_ICONS"
        printf 'ORM_3RDPARTY=%q\nORM_INSTALL_MANIFEST=%q\nORM_APPCONFIG=%q\n' "$ORM_3RDPARTY" "$ORM_INSTALL_MANIFEST" "$ORM_APPCONFIG"
        printf 'ORM_LIFECYCLE_LOCK=%q\nORM_SYSTEMCTL=%q\nORM_BROKER_BIN=%q\nORM_BROKER_LIB=%q\n' "$ORM_LIFECYCLE_LOCK" "$ORM_SYSTEMCTL" "$ORM_BROKER_BIN" "$ORM_BROKER_LIB"
        printf 'ORM_BROKER_UNIT=%q\nORM_INSTANCE_ROOT=%q\nORM_INSTANCE_DATA=%q\nORM_INSTANCE_UNIT=%q\n' "$ORM_BROKER_UNIT" "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA" "$ORM_INSTANCE_UNIT"
        printf 'ORM_INSTANCE_LAUNCHER=%q\nORM_METRICS_COLLECTOR=%q\nORM_METRICS_SERVICE=%q\nORM_METRICS_TIMER=%q\n' "$ORM_INSTANCE_LAUNCHER" "$ORM_METRICS_COLLECTOR" "$ORM_METRICS_SERVICE" "$ORM_METRICS_TIMER"
        printf 'ORM_BROKER_SOCKET=%q\n' "$ORM_BROKER_SOCKET"
        printf '# ORM_SCRIPT_BODY\n'
        tail -n +4 "$repo_root/packaging/upgrade.sh"
    } >"$runner"
    chmod 0755 "$runner"
    uninstall_runner="$test_root/uninstall-test.sh"
    {
        sed '/^# ORM_SCRIPT_BODY$/,$d' "$runner"
        tail -n +4 "$repo_root/packaging/uninstall.sh"
    } >"$uninstall_runner"
    chmod 0755 "$uninstall_runner"
}

run_upgrade_expect_success() {
    if ! bash "$test_root/upgrade-test.sh"; then
        printf 'expected the upgrade to succeed in %s.\n' "$test_root" >&2
        exit 1
    fi
}

prepare_empty_instance_roots() {
    mkdir -m 0711 "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"
}

assert_current_install_restored() {
    orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
        || { printf 'uninstall rollback did not restore the installed-file manifest.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_APPCONFIG_STATE")" == 1 && -f "$ORM_APPCONFIG" ]] \
        || { printf 'uninstall rollback did not restore WHM AppConfig registration.\n' >&2; exit 1; }
    cmp -s -- "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" "$ORM_APPCONFIG" \
        || { printf 'uninstall rollback changed the WHM AppConfig content.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_CPANEL_MARKER")" == current ]] \
        || { printf 'uninstall rollback did not restore the cPanel plugin.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == enabled && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active && -S "$TEST_SOCKET" ]] \
        || { printf 'uninstall rollback did not restore broker state.\n' >&2; exit 1; }
    [[ -d "$ORM_INSTANCE_ROOT" && -d "$ORM_INSTANCE_DATA" \
        && -z "$(find "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA" -mindepth 1 -print -quit)" ]] \
        || { printf 'uninstall rollback changed empty instance roots.\n' >&2; exit 1; }
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
        || { printf 'uninstall rollback left transaction files behind.\n' >&2; exit 1; }
}

assert_legacy_restored() {
    local allow_unexpected="${1:-0}" key target mode expected_files actual_files
    while IFS='|' read -r key target mode; do
        cmp -s -- "$fixture_root/$key" "$target" || { printf 'rollback did not restore %s.\n' "$key" >&2; exit 1; }
        [[ "$(stat -c '%a' -- "$target")" == "$mode" ]] || { printf 'rollback did not restore mode for %s.\n' "$key" >&2; exit 1; }
        [[ "$(stat -c '%u' -- "$target")" == 0 ]] || { printf 'rollback did not restore ownership for %s.\n' "$key" >&2; exit 1; }
    done < <(orm_legacy_identity_v1_file_map)
    expected_files="$(while IFS='|' read -r key target mode; do
        [[ "$target" == "$ORM_3RDPARTY/"* ]] && printf '%s\n' "$target"
    done < <(orm_legacy_identity_v1_file_map) | sort)"
    actual_files="$(find "$ORM_3RDPARTY" \( -type f -o -type l \) -print | sort)"
    if [[ "$allow_unexpected" != 1 ]]; then
        [[ "$expected_files" == "$actual_files" ]] || { printf 'rollback left unexpected files in the ORM package tree.\n' >&2; exit 1; }
    fi
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == "$EXPECTED_ENABLED" && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == "$EXPECTED_ACTIVE" ]] \
        || { printf 'rollback did not restore broker service state.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_CPANEL_MARKER")" == legacy && "$(cat "$TEST_APPCONFIG_STATE")" == 1 \
        && ! -e "$ORM_INSTALL_MANIFEST" ]] \
        || { printf 'rollback did not restore cPanel registration state.\n' >&2; exit 1; }
    cmp -s -- "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" "$ORM_APPCONFIG" \
        || { printf 'rollback changed the WHM AppConfig file.\n' >&2; exit 1; }
    [[ "$(stat -c '%i' "$ORM_APPCONFIG")" == "$TEST_APPCONFIG_INODE" ]] \
        || { printf 'rollback replaced the registered WHM AppConfig file.\n' >&2; exit 1; }
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
        || { printf 'rollback left a transaction temporary file behind.\n' >&2; exit 1; }
}

expect_preflight_refusal() {
    if bash "$test_root/upgrade-test.sh"; then
        printf 'expected preflight refusal in %s.\n' "$test_root" >&2
        exit 1
    fi
    # Preflight refusal must leave even the unexpected object that triggered it untouched.
    assert_legacy_restored 1
    [[ -S "$TEST_SOCKET" ]] || { printf 'preflight refusal changed the active broker socket.\n' >&2; exit 1; }
    [[ ! -s "$TEST_LOG" ]] || { printf 'preflight refusal ran a mutating command.\n' >&2; exit 1; }
}

prepare_case success
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
run_upgrade_expect_success
orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" || { printf 'new install manifest did not validate.\n' >&2; exit 1; }
[[ -S "$TEST_SOCKET" && ! -e "$ORM_INSTANCE_ROOT" && ! -e "$ORM_INSTANCE_DATA" ]] \
    || { printf 'successful upgrade changed an instance root or failed to restart the broker.\n' >&2; exit 1; }
[[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == enabled && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active ]] \
    || { printf 'successful upgrade changed broker enabled or active state.\n' >&2; exit 1; }
[[ "$(cat "$TEST_CPANEL_MARKER")" == current && "$(cat "$TEST_APPCONFIG_STATE")" == 1 ]] \
    || { printf 'successful upgrade did not preserve cPanel and WHM registration.\n' >&2; exit 1; }
[[ "$(stat -c '%i' "$ORM_APPCONFIG")" == "$TEST_APPCONFIG_INODE" ]] \
    || { printf 'successful upgrade replaced the registered WHM AppConfig file.\n' >&2; exit 1; }
! grep -q '^uninstall_plugin ' "$TEST_LOG" \
    || { printf 'successful upgrade removed the cPanel plugin registration before reinstalling it.\n' >&2; exit 1; }
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
    || { printf 'successful upgrade left a transaction temporary file behind.\n' >&2; exit 1; }

prepare_empty_instance_roots
bash "$test_root/uninstall-test.sh"
[[ ! -e "$ORM_3RDPARTY" && ! -e "$ORM_BROKER_UNIT" && ! -e "$ORM_APPCONFIG" \
    && ! -e "$ORM_INSTANCE_ROOT" && ! -e "$ORM_INSTANCE_DATA" \
    && ! -e "$TEST_CPANEL_MARKER" && "$(cat "$TEST_APPCONFIG_STATE")" == 0 \
    && "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == disabled \
    && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == inactive ]] \
    || { printf 'successful uninstall left ORM files, registration, instance roots, or broker service behind.\n' >&2; exit 1; }
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
    || { printf 'successful uninstall left transaction files behind.\n' >&2; exit 1; }
cleanup_test_root
trap - EXIT

prepare_case uninstall-unregistered-appconfig
run_upgrade_expect_success
prepare_empty_instance_roots
printf '0\n' >"$TEST_APPCONFIG_STATE"
: >"$TEST_LOG"
if bash "$test_root/uninstall-test.sh"; then
    printf 'expected uninstall refusal for an unregistered but present AppConfig file.\n' >&2
    exit 1
fi
[[ -f "$ORM_APPCONFIG" && -S "$TEST_SOCKET" && -e "$TEST_CPANEL_MARKER" \
    && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active && ! -s "$TEST_LOG" ]] \
    || { printf 'uninstall preflight changed an ambiguous AppConfig installation.\n' >&2; exit 1; }
cleanup_test_root
trap - EXIT

for failure in uninstall-plugin unregister-appconfig; do
    prepare_case "uninstall-rollback-$failure"
    run_upgrade_expect_success
    prepare_empty_instance_roots
    case "$failure" in
        uninstall-plugin) export TEST_FAIL_UNINSTALL_PLUGIN_ONCE=1 ;;
        unregister-appconfig) export TEST_FAIL_UNREGISTER_ONCE=1 ;;
    esac
    if bash "$test_root/uninstall-test.sh"; then
        printf 'expected injected uninstall failure at %s.\n' "$failure" >&2
        exit 1
    fi
    assert_current_install_restored
    cleanup_test_root
    trap - EXIT
    unset TEST_FAIL_UNINSTALL_PLUGIN_ONCE TEST_FAIL_UNREGISTER_ONCE
done

prepare_case draining
touch "$TEST_ROOT/busy-connection"
(sleep 2.5; rm -f -- "$TEST_ROOT/busy-connection") &
busy_cleanup_pid=$!
run_upgrade_expect_success
wait "$busy_cleanup_pid"
[[ -e "$TEST_ROOT/busy-connection-observed" ]] \
    || { printf 'the drain test never exposed an in-flight connection to the upgrader.\n' >&2; exit 1; }
[[ "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active ]] \
    || { printf 'the broker did not return to its active state after draining.\n' >&2; exit 1; }
cleanup_test_root
trap - EXIT

prepare_case plugin-rollback
export TEST_FAIL_CURRENT_PLUGIN_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected an injected cPanel registration failure.\n' >&2
    exit 1
fi
assert_legacy_restored
cleanup_test_root
trap - EXIT
unset TEST_FAIL_CURRENT_PLUGIN_ONCE

prepare_case start-rollback
export TEST_FAIL_START_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected an injected broker-start failure.\n' >&2
    exit 1
fi
assert_legacy_restored
cleanup_test_root
trap - EXIT
unset TEST_FAIL_START_ONCE

prepare_case reload-rollback
export TEST_FAIL_RELOAD_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected an injected systemd reload failure.\n' >&2
    exit 1
fi
assert_legacy_restored
cleanup_test_root
trap - EXIT
unset TEST_FAIL_RELOAD_ONCE

for state in 'disabled active' 'enabled inactive' 'disabled inactive'; do
    read -r initial_enabled initial_active <<<"$state"
    prepare_case "state-${initial_enabled}-${initial_active}" "$initial_enabled" "$initial_active"
    run_upgrade_expect_success
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == "$initial_enabled" \
        && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == "$initial_active" ]] \
        || { printf 'upgrade changed broker state (%s, %s).\n' "$initial_enabled" "$initial_active" >&2; exit 1; }
    if [[ "$initial_active" == active ]]; then [[ -S "$TEST_SOCKET" ]] || exit 1; else [[ ! -e "$TEST_SOCKET" ]] || exit 1; fi
    cleanup_test_root
    trap - EXIT
done

prepare_case file-rollback
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
export TEST_FAIL_FILE_INSTALL_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected an injected package-file install failure.\n' >&2
    exit 1
fi
assert_legacy_restored
cleanup_test_root
trap - EXIT
unset TEST_FAIL_FILE_INSTALL_ONCE

prepare_case disabled-active-rollback disabled active
EXPECTED_ENABLED=disabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
export TEST_FAIL_START_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected the disabled-active rollback case to fail at broker start.\n' >&2
    exit 1
fi
assert_legacy_restored
cleanup_test_root
trap - EXIT
unset TEST_FAIL_START_ONCE

prepare_case enabled-inactive-rollback enabled inactive
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=inactive
export EXPECTED_ENABLED EXPECTED_ACTIVE
export TEST_FAIL_CURRENT_PLUGIN_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected the enabled-inactive rollback case to fail during cPanel registration.\n' >&2
    exit 1
fi
assert_legacy_restored
cleanup_test_root
trap - EXIT
unset TEST_FAIL_CURRENT_PLUGIN_ONCE

prepare_case rollback-restoration-failure
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
export TEST_FAIL_FILE_INSTALL_ONCE=1
export TEST_FAIL_RESTORE_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected the injected rollback-restoration failure.\n' >&2
    exit 1
fi
[[ -e "$TEST_ROOT/restore-failure-used" && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == inactive \
    && "$(cat "$TEST_CPANEL_MARKER")" == legacy && ! -S "$TEST_SOCKET" ]] \
    || { printf 'rollback-restoration failure did not leave the broker stopped.\n' >&2; exit 1; }
recovery_backup="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'orm-upgrade.*' -print -quit)"
[[ -n "$recovery_backup" && -f "$recovery_backup/broker_server" ]] \
    || { printf 'incomplete rollback did not retain its recovery files.\n' >&2; exit 1; }
if grep -Fxq 'start' "$TEST_LOG"; then
    printf 'broker restarted despite an incomplete rollback.\n' >&2
    exit 1
fi
cleanup_test_root
trap - EXIT
unset TEST_FAIL_FILE_INSTALL_ONCE TEST_FAIL_RESTORE_ONCE

prepare_case tampered
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
printf 'tampered\n' >>"$ORM_3RDPARTY/bin/orm-broker.pl"
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected a tampered legacy file to be rejected.\n' >&2
    exit 1
fi
[[ "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active && -S "$TEST_SOCKET" \
    && -e "$TEST_CPANEL_MARKER" && ! -s "$TEST_LOG" && ! -e "$ORM_INSTALL_MANIFEST" ]] \
    || { printf 'tampered installation was mutated before rejection.\n' >&2; exit 1; }
cleanup_test_root
trap - EXIT

prepare_case unmanifested
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
printf 'unowned\n' >"$ORM_3RDPARTY/unexpected-file"
expect_preflight_refusal
cleanup_test_root
trap - EXIT

prepare_case existing-instance-root
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
mkdir -m 0711 "$ORM_INSTANCE_ROOT"
expect_preflight_refusal
cleanup_test_root
trap - EXIT

prepare_case unsafe-symlink
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
rm -f -- "$ORM_3RDPARTY/bin/orm-broker.pl"
ln -s "$fixture_root/broker_bin" "$ORM_3RDPARTY/bin/orm-broker.pl"
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected a symlinked legacy file to be rejected.\n' >&2
    exit 1
fi
[[ -L "$ORM_3RDPARTY/bin/orm-broker.pl" && -S "$TEST_SOCKET" && -e "$TEST_CPANEL_MARKER" && ! -s "$TEST_LOG" ]] \
    || { printf 'symlinked installation was mutated before rejection.\n' >&2; exit 1; }
cleanup_test_root
trap - EXIT

prepare_case registration-error
EXPECTED_ENABLED=enabled
EXPECTED_ACTIVE=active
export EXPECTED_ENABLED EXPECTED_ACTIVE
export TEST_FAIL_REGISTRATION_CHECK=1
expect_preflight_refusal
cleanup_test_root
trap - EXIT
unset TEST_FAIL_REGISTRATION_CHECK

printf 'Packaging upgrade integrity and rollback tests passed.\n'
