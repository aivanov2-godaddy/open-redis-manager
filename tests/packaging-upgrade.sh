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
managed_v1_root="$repo_root/packaging/legacy/managed-v1"
REAL_INSTALL="$(command -v install)"
REAL_CP="$(command -v cp)"
test_root=''
active_socket_pid=''
managed_fixture_expected="$(orm_legacy_managed_v1_file_map | awk -F'|' '{ print "files/" $1 }' | LC_ALL=C sort)"
managed_fixture_actual="$(tar -tzf "$managed_v1_root/fixtures.tar.gz" | LC_ALL=C sort)"
[[ "$managed_fixture_expected" == "$managed_fixture_actual" ]] \
    || { printf 'managed-v1 test fixture archive does not exactly match its 28-file map.\n' >&2; exit 1; }
cmp -s -- "$managed_v1_root/install.manifest" <(orm_legacy_managed_v1_expected_manifest) \
    || { printf 'managed-v1 install manifest does not match its immutable file map.\n' >&2; exit 1; }
cleanup_test_root() {
    local cleanup_status=$?
    if [[ -n "$test_root" && -f "$test_root/socket.pid" ]]; then kill "$(cat "$test_root/socket.pid")" 2>/dev/null || true; fi
    if [[ -n "$test_root" && -f "$test_root/initial-socket.pid" ]]; then kill "$(cat "$test_root/initial-socket.pid")" 2>/dev/null || true; fi
    if [[ -n "$active_socket_pid" ]]; then kill "$active_socket_pid" 2>/dev/null || true; fi
    if [[ "${TEST_KEEP_FAILED_ROOT:-0}" == 1 && "$cleanup_status" -ne 0 && -n "$test_root" ]]; then
        printf 'packaging test artifacts retained at %s\n' "$test_root" >&2
        return 0
    fi
    if [[ -n "$test_root" ]]; then rm -rf -- "$test_root"; fi
}
trap cleanup_test_root EXIT

prepare_case() {
    local case_name="$1" initial_enabled="${2:-enabled}" initial_active="${3:-active}" baseline="${4:-identity}" key source target mode
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
    export TEST_CURRENT_FEATURE_SHA="$(sha256sum "$ORM_PACKAGE_ROOT/cpanel/icons/orm-cpanel-feature-v4.png" | awk '{print $1}')"
    export TEST_LEGACY_FEATURE_SHA="$(sha256sum "$ORM_PACKAGE_ROOT/legacy/identity-v1/cpanel/icons/orm-feature.svg" | awk '{print $1}')"
    export TEST_MANAGED_FEATURE_SHA="$(sha256sum "$managed_v1_root/cpanel/orm-feature.svg" | awk '{print $1}')"
    export TEST_UPGRADE_BASELINE="$baseline"
    export TEST_MANAGED_FIXTURE_ROOT="$test_root/managed-v1-fixture"
    export TEST_PODMAN_ROOT="$test_root/home/test-account/ea-podman.d/ea-redis62.test-account.01"
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
if tar -tzf "$1" | grep -Fxq orm-cpanel-feature-v4.png; then
    feature_sha="$(tar -xOzf "$1" orm-cpanel-feature-v4.png | sha256sum | awk '{print $1}')"
else
    feature_sha="$(tar -xOzf "$1" orm-feature.svg | sha256sum | awk '{print $1}')"
fi
if [[ "$feature_sha" == "$TEST_CURRENT_FEATURE_SHA" ]]; then
    plugin_state=current
elif [[ "$feature_sha" == "$TEST_MANAGED_FEATURE_SHA" ]]; then
    plugin_state=legacy-managed
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
feature_sha="$(tar -xOzf "$1" orm-cpanel-feature-v4.png | sha256sum | awk '{print $1}')"
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
printf '\nname=open_redis_manager\n' >>"$ORM_APPCONFIG"
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
    is-enabled)
        if [[ "${2:-}" == orm-provider-events.timer ]]; then cat "$TEST_SYSTEMCTL_STATE.events-enabled"
        elif [[ "${2:-}" == orm-podman-metrics.timer ]]; then cat "$TEST_SYSTEMCTL_STATE.podman-enabled"
        else cat "$enabled_file"; fi
        ;;
    is-active)
        if [[ "${2:-}" == orm-provider-events.timer || "${2:-}" == orm-provider-events.service ]]; then cat "$TEST_SYSTEMCTL_STATE.events-active"
        elif [[ "${2:-}" == orm-podman-metrics.timer || "${2:-}" == orm-podman-metrics.service ]]; then cat "$TEST_SYSTEMCTL_STATE.podman-active"
        else cat "$active_file"; fi
        ;;
    enable)
        if [[ "${2:-}" == --now && "${3:-}" == orm-provider-events.timer ]]; then
            printf 'enabled\n' >"$TEST_SYSTEMCTL_STATE.events-enabled"
            printf 'active\n' >"$TEST_SYSTEMCTL_STATE.events-active"
        elif [[ "${2:-}" == --now && "${3:-}" == orm-podman-metrics.timer ]]; then
            printf 'enabled\n' >"$TEST_SYSTEMCTL_STATE.podman-enabled"
            printf 'active\n' >"$TEST_SYSTEMCTL_STATE.podman-active"
        else
            printf 'enabled\n' >"$enabled_file"
        fi
        ;;
    disable)
        if [[ "${3:-}" == orm-provider-events.timer ]]; then
            printf 'disabled\n' >"$TEST_SYSTEMCTL_STATE.events-enabled"
            printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.events-active"
        elif [[ "${3:-}" == orm-podman-metrics.timer ]]; then
            printf 'disabled\n' >"$TEST_SYSTEMCTL_STATE.podman-enabled"
            printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.podman-active"
        else
            printf 'disabled\n' >"$enabled_file"
        fi
        if [[ "${2:-}" == --now && "${3:-}" != orm-provider-events.timer && "${3:-}" != orm-podman-metrics.timer ]]; then
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
        if [[ "${2:-}" == orm-provider-events.service ]]; then
            printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.events-active"
            exit 0
        fi
        if [[ "${2:-}" == orm-podman-metrics.service ]]; then
            printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.podman-active"
            exit 0
        fi
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
        printf 'active\n' >"$active_file"
        perl -MIO::Socket::UNIX -MSocket=SOCK_STREAM -e 'sleep 0.25; $s=IO::Socket::UNIX->new(Type=>SOCK_STREAM,Local=>$ARGV[0],Listen=>64) or die $!; chmod 0666,$ARGV[0] or die $!; $SIG{TERM}=sub { close $s; exit }; sleep 3600' "$TEST_SOCKET" >/dev/null 2>&1 </dev/null &
        printf '%s\n' "$!" >"$TEST_ROOT/socket.pid"
        ;;
    *) exit 2 ;;
esac
MOCK
    cat >"$test_root/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'state established'* ]]; then
    printf 'u_str ESTAB 0 0 * 2917516 * 2913697 users:(("perl",pid=4242,fd=1),("perl",pid=4242,fd=2))\n'
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
if [[ "${TEST_INTERRUPT_FILE_INSTALL_ONCE:-0}" == 1 && "${1:-}" == -m && "${3:-}" == *Server.pm && ! -e "$TEST_ROOT/file-interruption-used" ]]; then
    : >"$TEST_ROOT/file-interruption-used"
    "$TEST_REAL_INSTALL" "$@" || exit
    kill -TERM "$PPID"
    exit 0
fi
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
    export TEST_INITIAL_ENABLED="$initial_enabled" TEST_INITIAL_ACTIVE="$initial_active"
    printf 'legacy\n' >"$TEST_CPANEL_MARKER"
    printf '1\n' >"$TEST_APPCONFIG_STATE"
    cp -- "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" "$test_root/var/cpanel/apps/open_redis_manager.conf"
    chmod 0600 "$test_root/var/cpanel/apps/open_redis_manager.conf"

    ORM_CPANEL_ROOT="$test_root/cpanel"
    ORM_MANAGE_HOOKS="$ORM_CPANEL_ROOT/bin/manage_hooks"
    ORM_ACCOUNT_CREATE_HOOK="$ORM_CPANEL_ROOT/3rdparty/bin/orm-account-create-hook.php"
    TEST_HOOK_REGISTRY="$test_root/manage-hooks.state"
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
    mkdir -p -- "$test_root/var/lib"
    ORM_INSTANCE_UNIT="$test_root/etc/systemd/system/orm-instance@.service"
    ORM_INSTANCE_LAUNCHER="$ORM_3RDPARTY/bin/orm-instance-launcher"
    ORM_METRICS_COLLECTOR="$ORM_3RDPARTY/bin/orm-metrics-collect.pl"
    ORM_METRICS_SERVICE="$test_root/etc/systemd/system/orm-metrics-collect@.service"
    ORM_METRICS_TIMER="$test_root/etc/systemd/system/orm-metrics-collect@.timer"
    ORM_PROVIDER_EVENTS_CONFIG="$test_root/etc/orm-provider-events.json"
    ORM_PROVIDER_EVENTS_ROOT="$test_root/var/lib/orm-events"
    ORM_PROVIDER_EVENTS_OUTBOX="$ORM_PROVIDER_EVENTS_ROOT/outbox"
    ORM_PROVIDER_EVENTS_SERVICE="$test_root/etc/systemd/system/orm-provider-events.service"
    ORM_PROVIDER_EVENTS_TIMER="$test_root/etc/systemd/system/orm-provider-events.timer"
    ORM_PODMAN_METRICS_SERVICE="$test_root/etc/systemd/system/orm-podman-metrics.service"
    ORM_PODMAN_METRICS_TIMER="$test_root/etc/systemd/system/orm-podman-metrics.timer"
    ORM_BROKER_SOCKET="$TEST_SOCKET"
    mkdir -p -- "$test_root/etc/systemd/system" "$test_root/var/lib"
    printf 'disabled\n' >"$TEST_SYSTEMCTL_STATE.events-enabled"
    printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.events-active"
    printf 'disabled\n' >"$TEST_SYSTEMCTL_STATE.podman-enabled"
    printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.podman-active"
    cat >"$ORM_MANAGE_HOOKS" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    list)
        if [[ -f "$TEST_HOOK_REGISTRY" ]]; then
            printf 'Whostmgr:\n   Accounts::Create:\n      stage: post\n      exectype: script\n      hook: %s --run\n' "$(<"$TEST_HOOK_REGISTRY")"
        else
            printf 'Whostmgr:\n'
        fi
        ;;
    add)
        [[ "$2" == script && "$3" == "$ORM_ACCOUNT_CREATE_HOOK" ]]
        printf '%s\n' "$ORM_ACCOUNT_CREATE_HOOK" >"$TEST_HOOK_REGISTRY"
        ;;
    delete)
        [[ "$2" == script && "$3" == "$ORM_ACCOUNT_CREATE_HOOK" ]]
        rm -f -- "$TEST_HOOK_REGISTRY"
        ;;
    *) exit 2 ;;
esac
MOCK
    chmod 0755 "$ORM_MANAGE_HOOKS"
    export ORM_CPANEL_ROOT ORM_MANAGE_HOOKS ORM_ACCOUNT_CREATE_HOOK TEST_HOOK_REGISTRY
    export ORM_INSTALL_PLUGIN ORM_UNINSTALL_PLUGIN ORM_REGISTER_APPCONFIG ORM_UNREGISTER_APPCONFIG
    export ORM_IS_REGISTERED ORM_CPanel_LIVE ORM_WHM_CGI ORM_WHM_ICONS ORM_3RDPARTY ORM_INSTALL_MANIFEST ORM_APPCONFIG
    export ORM_LIFECYCLE_LOCK ORM_SYSTEMCTL ORM_BROKER_BIN ORM_BROKER_LIB ORM_BROKER_UNIT ORM_INSTANCE_ROOT
    export ORM_INSTANCE_DATA ORM_INSTANCE_UNIT ORM_INSTANCE_LAUNCHER ORM_METRICS_COLLECTOR ORM_METRICS_SERVICE
    export ORM_METRICS_TIMER ORM_BROKER_SOCKET
    export ORM_PROVIDER_EVENTS_CONFIG ORM_PROVIDER_EVENTS_ROOT ORM_PROVIDER_EVENTS_OUTBOX
    export ORM_PROVIDER_EVENTS_SERVICE ORM_PROVIDER_EVENTS_TIMER
    export ORM_PODMAN_METRICS_SERVICE ORM_PODMAN_METRICS_TIMER
    if [[ "$baseline" == managed ]]; then
        mkdir -p -- "$TEST_MANAGED_FIXTURE_ROOT"
        tar -xzf "$managed_v1_root/fixtures.tar.gz" -C "$TEST_MANAGED_FIXTURE_ROOT"
        while IFS='|' read -r key source target mode digest; do
            mkdir -p -- "$(dirname -- "$target")"
            install -m "$mode" "$TEST_MANAGED_FIXTURE_ROOT/files/$key" "$target"
        done < <(orm_legacy_managed_v1_file_map)
        install -m 0600 "$managed_v1_root/install.manifest" "$ORM_INSTALL_MANIFEST"
        printf 'legacy-managed\n' >"$TEST_CPANEL_MARKER"
        mkdir -m 0711 -- "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"
        mkdir -p -- "$ORM_INSTANCE_ROOT/accounts/test-account" "$ORM_INSTANCE_DATA/test-account/data" "$TEST_PODMAN_ROOT"
        printf 'instance metadata sentinel\n' >"$ORM_INSTANCE_ROOT/accounts/test-account/metadata.json"
        printf 'instance data sentinel\n' >"$ORM_INSTANCE_DATA/test-account/data/dump.rdb"
        printf 'cPanel Podman sentinel\n' >"$TEST_PODMAN_ROOT/container.json"
        chmod 0600 -- "$ORM_INSTANCE_ROOT/accounts/test-account/metadata.json" \
            "$ORM_INSTANCE_DATA/test-account/data/dump.rdb" "$TEST_PODMAN_ROOT/container.json"
        export TEST_INSTANCE_ROOT_ID="$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_ROOT")"
        export TEST_INSTANCE_DATA_ID="$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_DATA")"
        export TEST_INSTANCE_METADATA_SHA="$(sha256sum "$ORM_INSTANCE_ROOT/accounts/test-account/metadata.json" | awk '{print $1}')"
        export TEST_INSTANCE_DATA_SHA="$(sha256sum "$ORM_INSTANCE_DATA/test-account/data/dump.rdb" | awk '{print $1}')"
        export TEST_PODMAN_SENTINEL_SHA="$(sha256sum "$TEST_PODMAN_ROOT/container.json" | awk '{print $1}')"
    else
        while IFS='|' read -r key target mode; do
            mkdir -p -- "$(dirname -- "$target")"
            install -m "$mode" "$fixture_root/$key" "$target"
        done < <(orm_legacy_identity_v1_file_map)
    fi
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
        printf 'ORM_MANAGE_HOOKS=%q\nORM_ACCOUNT_CREATE_HOOK=%q\nTEST_HOOK_REGISTRY=%q\n' \
            "$ORM_MANAGE_HOOKS" "$ORM_ACCOUNT_CREATE_HOOK" "$TEST_HOOK_REGISTRY"
        printf 'ORM_INSTALL_PLUGIN=%q\nORM_UNINSTALL_PLUGIN=%q\n' "$ORM_INSTALL_PLUGIN" "$ORM_UNINSTALL_PLUGIN"
        printf 'ORM_REGISTER_APPCONFIG=%q\nORM_UNREGISTER_APPCONFIG=%q\nORM_IS_REGISTERED=%q\n' "$ORM_REGISTER_APPCONFIG" "$ORM_UNREGISTER_APPCONFIG" "$ORM_IS_REGISTERED"
        printf 'ORM_CPanel_LIVE=%q\nORM_WHM_CGI=%q\nORM_WHM_ICONS=%q\n' "$ORM_CPanel_LIVE" "$ORM_WHM_CGI" "$ORM_WHM_ICONS"
        printf 'ORM_3RDPARTY=%q\nORM_INSTALL_MANIFEST=%q\nORM_APPCONFIG=%q\n' "$ORM_3RDPARTY" "$ORM_INSTALL_MANIFEST" "$ORM_APPCONFIG"
        printf 'ORM_LIFECYCLE_LOCK=%q\nORM_SYSTEMCTL=%q\nORM_BROKER_BIN=%q\nORM_BROKER_LIB=%q\n' "$ORM_LIFECYCLE_LOCK" "$ORM_SYSTEMCTL" "$ORM_BROKER_BIN" "$ORM_BROKER_LIB"
        printf 'ORM_BROKER_UNIT=%q\nORM_INSTANCE_ROOT=%q\nORM_INSTANCE_DATA=%q\nORM_INSTANCE_UNIT=%q\n' "$ORM_BROKER_UNIT" "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA" "$ORM_INSTANCE_UNIT"
        printf 'ORM_INSTANCE_LAUNCHER=%q\nORM_METRICS_COLLECTOR=%q\nORM_METRICS_SERVICE=%q\nORM_METRICS_TIMER=%q\n' "$ORM_INSTANCE_LAUNCHER" "$ORM_METRICS_COLLECTOR" "$ORM_METRICS_SERVICE" "$ORM_METRICS_TIMER"
        printf 'ORM_BROKER_SOCKET=%q\n' "$ORM_BROKER_SOCKET"
        printf 'ORM_PROVIDER_EVENTS_CONFIG=%q\nORM_PROVIDER_EVENTS_ROOT=%q\nORM_PROVIDER_EVENTS_OUTBOX=%q\n' \
            "$ORM_PROVIDER_EVENTS_CONFIG" "$ORM_PROVIDER_EVENTS_ROOT" "$ORM_PROVIDER_EVENTS_OUTBOX"
        printf 'ORM_PROVIDER_EVENTS_SERVICE=%q\nORM_PROVIDER_EVENTS_TIMER=%q\n' \
            "$ORM_PROVIDER_EVENTS_SERVICE" "$ORM_PROVIDER_EVENTS_TIMER"
        printf 'ORM_PODMAN_METRICS_SERVICE=%q\nORM_PODMAN_METRICS_TIMER=%q\n' \
            "$ORM_PODMAN_METRICS_SERVICE" "$ORM_PODMAN_METRICS_TIMER"
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
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.podman-enabled")" == enabled && "$(cat "$TEST_SYSTEMCTL_STATE.podman-active")" == active ]] \
        || { printf 'upgrade did not enable the EA Podman metrics timer.\n' >&2; exit 1; }
}

prepare_empty_instance_roots() {
    mkdir -p -m 0711 "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"
}

assert_current_install_restored() {
    orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
        || { printf 'uninstall rollback did not restore the installed-file manifest.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_APPCONFIG_STATE")" == 1 && -f "$ORM_APPCONFIG" ]] \
        || { printf 'uninstall rollback did not restore WHM AppConfig registration.\n' >&2; exit 1; }
    orm_appconfig_matches_package "$ORM_APPCONFIG" \
        || { printf 'uninstall rollback changed the WHM AppConfig content.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_CPANEL_MARKER")" == current ]] \
        || { printf 'uninstall rollback did not restore the cPanel plugin.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == enabled && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active && -S "$TEST_SOCKET" ]] \
        || { printf 'uninstall rollback did not restore broker state.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.podman-enabled")" == enabled && "$(cat "$TEST_SYSTEMCTL_STATE.podman-active")" == active ]] \
        || { printf 'uninstall rollback did not restore the EA Podman metrics timer.\n' >&2; exit 1; }
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
        if [[ "$target" == "$ORM_3RDPARTY/"* ]]; then printf '%s\n' "$target"; fi
    done < <(orm_legacy_identity_v1_file_map) | sort)"
    actual_files="$(find "$ORM_3RDPARTY" \( -type f -o -type l \) -print | sort)"
    if [[ "$allow_unexpected" != 1 ]]; then
        [[ "$expected_files" == "$actual_files" ]] || { printf 'rollback left unexpected files in the ORM package tree.\n' >&2; exit 1; }
        [[ ! -e "$ORM_INSTANCE_ROOT" && ! -L "$ORM_INSTANCE_ROOT" \
            && ! -e "$ORM_INSTANCE_DATA" && ! -L "$ORM_INSTANCE_DATA" ]] \
            || { printf 'rollback left transaction-created instance roots behind.\n' >&2; exit 1; }
    fi
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == "$EXPECTED_ENABLED" && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == "$EXPECTED_ACTIVE" ]] \
        || { printf 'rollback did not restore broker service state.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_CPANEL_MARKER")" == legacy && "$(cat "$TEST_APPCONFIG_STATE")" == 1 \
        && ! -e "$ORM_INSTALL_MANIFEST" ]] \
        || { printf 'rollback did not restore cPanel registration state.\n' >&2; exit 1; }
    orm_appconfig_matches_package "$ORM_APPCONFIG" \
        || { printf 'rollback changed the WHM AppConfig file.\n' >&2; exit 1; }
    [[ "$(stat -c '%i' "$ORM_APPCONFIG")" == "$TEST_APPCONFIG_INODE" ]] \
        || { printf 'rollback replaced the registered WHM AppConfig file.\n' >&2; exit 1; }
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
        || { printf 'rollback left a transaction temporary file behind.\n' >&2; exit 1; }
}

assert_managed_legacy_restored() {
    orm_validate_legacy_managed_v1 \
        || { printf 'rollback did not restore the exact managed-v1 file set and manifest.\n' >&2; exit 1; }
    [[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == "$TEST_INITIAL_ENABLED" \
        && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == "$TEST_INITIAL_ACTIVE" ]] \
        || { printf 'managed-v1 rollback changed broker service state.\n' >&2; exit 1; }
    if [[ "$TEST_INITIAL_ACTIVE" == active ]]; then
        [[ -S "$TEST_SOCKET" ]] || { printf 'managed-v1 rollback did not restore the broker socket.\n' >&2; exit 1; }
    else
        [[ ! -e "$TEST_SOCKET" && ! -L "$TEST_SOCKET" ]] \
            || { printf 'managed-v1 rollback created an inactive broker socket.\n' >&2; exit 1; }
    fi
    [[ "$(cat "$TEST_CPANEL_MARKER")" == legacy-managed \
        && "$(cat "$TEST_APPCONFIG_STATE")" == 1 ]] \
        || { printf 'managed-v1 rollback did not restore the exact cPanel and WHM registration.\n' >&2; exit 1; }
    [[ "$(stat -c '%i' "$ORM_APPCONFIG")" == "$TEST_APPCONFIG_INODE" ]] \
        || { printf 'managed-v1 rollback replaced the unchanged WHM AppConfig file.\n' >&2; exit 1; }
    [[ "$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_ROOT")" == "$TEST_INSTANCE_ROOT_ID" \
        && "$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_DATA")" == "$TEST_INSTANCE_DATA_ID" ]] \
        || { printf 'managed-v1 rollback changed an existing instance root.\n' >&2; exit 1; }
    [[ "$(sha256sum "$ORM_INSTANCE_ROOT/accounts/test-account/metadata.json" | awk '{print $1}')" == "$TEST_INSTANCE_METADATA_SHA" \
        && "$(sha256sum "$ORM_INSTANCE_DATA/test-account/data/dump.rdb" | awk '{print $1}')" == "$TEST_INSTANCE_DATA_SHA" \
        && "$(sha256sum "$TEST_PODMAN_ROOT/container.json" | awk '{print $1}')" == "$TEST_PODMAN_SENTINEL_SHA" ]] \
        || { printf 'managed-v1 rollback changed instance or cPanel Podman data.\n' >&2; exit 1; }
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
        || { printf 'managed-v1 rollback left transaction temporary files behind.\n' >&2; exit 1; }
}

managed_preflight_snapshot() {
    local path
    local -a roots=()
    for path in "$ORM_3RDPARTY" "$ORM_CPanel_LIVE" "$ORM_INSTANCE_ROOT" \
        "$ORM_INSTANCE_DATA" "$TEST_PODMAN_ROOT" "$TEST_ROOT/instance-root-saved"; do
        [[ -e "$path" || -L "$path" ]] && roots+=("$path")
    done
    {
        find "${roots[@]}" -print0
        printf '%s\0' "$ORM_INSTALL_MANIFEST" "$ORM_APPCONFIG" "$TEST_SOCKET" \
            "$TEST_CPANEL_MARKER" "$TEST_APPCONFIG_STATE" "$TEST_SYSTEMCTL_STATE.enabled" \
            "$TEST_SYSTEMCTL_STATE.active" "$TEST_LOG"
    } | LC_ALL=C sort -zu | while IFS= read -r -d '' path; do
        if [[ ! -e "$path" && ! -L "$path" ]]; then
            printf 'missing|%s\n' "$path"
            continue
        fi
        stat -c 'meta|%F|%u:%g|%a|%d:%i|%n' -- "$path"
        if [[ -f "$path" && ! -L "$path" ]]; then
            sha256sum -- "$path"
        elif [[ -L "$path" ]]; then
            printf 'link|%s|%s\n' "$path" "$(readlink -- "$path")"
        fi
    done
}

expect_managed_preflight_refusal() {
    local before after
    before="$(managed_preflight_snapshot)"
    if bash "$test_root/upgrade-test.sh"; then
        printf 'expected managed-v1 preflight refusal in %s.\n' "$test_root" >&2
        exit 1
    fi
    after="$(managed_preflight_snapshot)"
    [[ "$before" == "$after" && ! -s "$TEST_LOG" ]] \
        || { printf 'managed-v1 preflight refusal changed protected state or ran a mutating command.\n' >&2; exit 1; }
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
[[ "$(orm_install_manifest_version "$ORM_INSTALL_MANIFEST")" == "$(cat "$ORM_VERSION_FILE")" ]] \
    || { printf 'successful identity bridge did not record the package version.\n' >&2; exit 1; }
[[ -S "$TEST_SOCKET" && -d "$ORM_INSTANCE_ROOT" && ! -L "$ORM_INSTANCE_ROOT" \
    && -d "$ORM_INSTANCE_DATA" && ! -L "$ORM_INSTANCE_DATA" \
    && "$(stat -c '%u:%a' "$ORM_INSTANCE_ROOT")" == 0:711 \
    && "$(stat -c '%u:%a' "$ORM_INSTANCE_DATA")" == 0:711 \
    && -z "$(find "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA" -mindepth 1 -print -quit)" ]] \
    || { printf 'successful upgrade did not create only secure, empty instance roots or failed to restart the broker.\n' >&2; exit 1; }
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
bash "$test_root/uninstall-test.sh"
[[ ! -e "$ORM_3RDPARTY" && ! -e "$ORM_BROKER_UNIT" && ! -e "$ORM_APPCONFIG" \
    && ! -e "$ORM_INSTANCE_ROOT" && ! -e "$ORM_INSTANCE_DATA" \
    && ! -e "$TEST_CPANEL_MARKER" && "$(cat "$TEST_APPCONFIG_STATE")" == 0 \
    && "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == disabled \
    && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == inactive ]] \
    || { printf 'repeated uninstall changed service or registration state.\n' >&2; exit 1; }
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
    || { printf 'repeated uninstall left temporary files behind.\n' >&2; exit 1; }
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
(
    for attempt in {1..200}; do
        if [[ -e "$TEST_ROOT/busy-connection-observed" ]]; then
            sleep 0.25
            rm -f -- "$TEST_ROOT/busy-connection"
            exit 0
        fi
        sleep 0.05
    done
    exit 1
) &
busy_cleanup_pid=$!
run_upgrade_expect_success
wait "$busy_cleanup_pid" || { printf 'the drain test did not expose an in-flight connection before its timeout.\n' >&2; exit 1; }
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

prepare_case managed-success enabled active managed
run_upgrade_expect_success
orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
    || { printf 'managed-v1 upgrade did not create a valid current manifest.\n' >&2; exit 1; }
[[ "$(cat "$TEST_CPANEL_MARKER")" == current && "$(cat "$TEST_APPCONFIG_STATE")" == 1 \
    && "$(stat -c '%i' "$ORM_APPCONFIG")" == "$TEST_APPCONFIG_INODE" \
    && "$(sha256sum "$ORM_APPCONFIG" | awk '{print $1}')" == "$(sha256sum "$TEST_MANAGED_FIXTURE_ROOT/files/whm_appconfig" | awk '{print $1}')" ]] \
    || { printf 'managed-v1 upgrade changed WHM or cPanel registration unexpectedly.\n' >&2; exit 1; }
[[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == enabled \
    && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active && -S "$TEST_SOCKET" ]] \
    || { printf 'managed-v1 upgrade failed to preserve enabled broker state.\n' >&2; exit 1; }
[[ "$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_ROOT")" == "$TEST_INSTANCE_ROOT_ID" \
    && "$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_DATA")" == "$TEST_INSTANCE_DATA_ID" \
    && "$(sha256sum "$ORM_INSTANCE_ROOT/accounts/test-account/metadata.json" | awk '{print $1}')" == "$TEST_INSTANCE_METADATA_SHA" \
    && "$(sha256sum "$ORM_INSTANCE_DATA/test-account/data/dump.rdb" | awk '{print $1}')" == "$TEST_INSTANCE_DATA_SHA" \
    && "$(sha256sum "$TEST_PODMAN_ROOT/container.json" | awk '{print $1}')" == "$TEST_PODMAN_SENTINEL_SHA" ]] \
    || { printf 'managed-v1 upgrade changed existing instance or cPanel Podman data.\n' >&2; exit 1; }
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] \
    || { printf 'managed-v1 upgrade left transaction temporary files behind.\n' >&2; exit 1; }
cleanup_test_root
trap - EXIT

prepare_case managed-inactive disabled inactive managed
run_upgrade_expect_success
[[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == disabled \
    && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == inactive \
    && ! -e "$TEST_SOCKET" && ! -L "$TEST_SOCKET" \
    && "$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_ROOT")" == "$TEST_INSTANCE_ROOT_ID" \
    && "$(stat -c '%d:%i:%u:%a' "$ORM_INSTANCE_DATA")" == "$TEST_INSTANCE_DATA_ID" \
    && "$(sha256sum "$TEST_PODMAN_ROOT/container.json" | awk '{print $1}')" == "$TEST_PODMAN_SENTINEL_SHA" ]] \
    || { printf 'managed-v1 upgrade changed inactive broker or existing data state.\n' >&2; exit 1; }
cleanup_test_root
trap - EXIT

for failure in plugin file reload start; do
    printf 'Testing managed-v1 rollback after %s failure.\n' "$failure"
    prepare_case "managed-rollback-$failure" enabled active managed
    case "$failure" in
        plugin) export TEST_FAIL_CURRENT_PLUGIN_ONCE=1 ;;
        file) export TEST_FAIL_FILE_INSTALL_ONCE=1 ;;
        reload) export TEST_FAIL_RELOAD_ONCE=1 ;;
        start) export TEST_FAIL_START_ONCE=1 ;;
    esac
    if bash "$test_root/upgrade-test.sh"; then
        printf 'expected managed-v1 injected upgrade failure at %s.\n' "$failure" >&2
        exit 1
    fi
    assert_managed_legacy_restored
    cleanup_test_root
    trap - EXIT
    unset TEST_FAIL_CURRENT_PLUGIN_ONCE TEST_FAIL_FILE_INSTALL_ONCE TEST_FAIL_RELOAD_ONCE TEST_FAIL_START_ONCE
done

printf 'Testing managed-v1 rollback after TERM during file installation.\n'
prepare_case managed-rollback-interrupted enabled active managed
export TEST_INTERRUPT_FILE_INSTALL_ONCE=1
if bash "$test_root/upgrade-test.sh"; then
    printf 'expected managed-v1 upgrade to stop after the injected TERM signal.\n' >&2
    exit 1
fi
[[ -e "$TEST_ROOT/file-interruption-used" ]] \
    || { printf 'the managed-v1 interruption signal was not injected.\n' >&2; exit 1; }
assert_managed_legacy_restored
cleanup_test_root
trap - EXIT
unset TEST_INTERRUPT_FILE_INSTALL_ONCE

for drift in manifest target extra-file empty-directory appconfig appconfig-mode cpanel-entry instance-mode instance-symlink; do
    prepare_case "managed-drift-$drift" disabled inactive managed
    case "$drift" in
        manifest) printf 'tampered\n' >>"$ORM_INSTALL_MANIFEST" ;;
        target) printf 'tampered\n' >>"$ORM_3RDPARTY/bin/orm-broker.pl" ;;
        extra-file) printf 'unowned\n' >"$ORM_3RDPARTY/unexpected-file" ;;
        empty-directory) mkdir -p -- "$ORM_3RDPARTY/unexpected/empty" ;;
        appconfig) printf 'tampered\n' >>"$ORM_APPCONFIG" ;;
        appconfig-mode) chmod 0644 -- "$ORM_APPCONFIG" ;;
        cpanel-entry) printf 'extra\n' >"$ORM_CPanel_LIVE/unexpected.php" ;;
        instance-mode) chmod 0700 -- "$ORM_INSTANCE_ROOT" ;;
        instance-symlink)
            mv -- "$ORM_INSTANCE_ROOT" "$TEST_ROOT/instance-root-saved"
            ln -s -- "$TEST_ROOT/instance-root-saved" "$ORM_INSTANCE_ROOT"
            ;;
    esac
    expect_managed_preflight_refusal
    cleanup_test_root
    trap - EXIT
done

printf 'Packaging upgrade integrity and rollback tests passed.\n'
