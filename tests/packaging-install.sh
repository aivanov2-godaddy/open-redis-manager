#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'packaging install tests must run as root.\n' >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd -P)"
source "$repo_root/packaging/lib.sh"
base_path="$PATH"
test_case_root="$(mktemp -d /tmp/orm-install-test.XXXXXXXX)"
test_root=""
trap '[[ -z "$test_case_root" || ! -d "$test_case_root" ]] || rm -rf -- "$test_case_root"' EXIT

configure_case() {
    local case_name="$1"
    test_root="$test_case_root/$case_name"
    TEST_ROOT="$test_root"
    TEST_TMPDIR="$test_root/tmp"
    TEST_PLUGIN_STATE="$test_root/cpanel-plugin-state"
    TEST_APPCONFIG_STATE="$test_root/appconfig-state"
    TEST_SYSTEMCTL_STATE="$test_root/systemctl-state"
    TEST_PACKAGE_APPCONFIG="$repo_root/packaging/whm/open_redis_manager.conf"
    ORM_CPANEL_ROOT="$test_root/cpanel"
    ORM_INSTALL_PLUGIN="$test_root/bin/install_plugin"
    ORM_UNINSTALL_PLUGIN="$test_root/bin/uninstall_plugin"
    ORM_REGISTER_APPCONFIG="$test_root/bin/register_appconfig"
    ORM_UNREGISTER_APPCONFIG="$test_root/bin/unregister_appconfig"
    ORM_IS_REGISTERED="$test_root/bin/is_registered_with_appconfig"
    ORM_CPanel_THEME=jupiter
    ORM_CPanel_LIVE="$ORM_CPANEL_ROOT/base/frontend/$ORM_CPanel_THEME/orm"
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
    ORM_BROKER_SOCKET="$test_root/run/orm/broker.sock"
    TMPDIR="$TEST_TMPDIR"
    PATH="$test_root/bin:$base_path"
    export TEST_ROOT TEST_TMPDIR TEST_PLUGIN_STATE TEST_APPCONFIG_STATE TEST_SYSTEMCTL_STATE TEST_PACKAGE_APPCONFIG TMPDIR PATH
    export ORM_CPANEL_ROOT ORM_INSTALL_PLUGIN ORM_UNINSTALL_PLUGIN ORM_REGISTER_APPCONFIG ORM_UNREGISTER_APPCONFIG
    export ORM_IS_REGISTERED ORM_CPanel_THEME ORM_CPanel_LIVE ORM_WHM_CGI ORM_WHM_ICONS ORM_3RDPARTY
    export ORM_INSTALL_MANIFEST ORM_APPCONFIG ORM_LIFECYCLE_LOCK ORM_SYSTEMCTL ORM_BROKER_BIN ORM_BROKER_LIB
    export ORM_BROKER_UNIT ORM_INSTANCE_ROOT ORM_INSTANCE_DATA ORM_INSTANCE_UNIT ORM_INSTANCE_LAUNCHER
    export ORM_METRICS_COLLECTOR ORM_METRICS_SERVICE ORM_METRICS_TIMER ORM_BROKER_SOCKET

    mkdir -p "$test_root/bin" "$test_root/cpanel/php" "$test_root/var/cpanel/apps" \
        "$test_root/etc/systemd/system" "$test_root/var/lib" "$test_root/run" "$TEST_TMPDIR"
    : >"$test_root/cpanel/php/WHM.php"
    : >"$test_root/cpanel/php/cpanel.php"
    printf '0\n' >"$TEST_APPCONFIG_STATE"
    printf 'disabled\n' >"$TEST_SYSTEMCTL_STATE.enabled"
    printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.active"

    cat >"$ORM_INSTALL_PLUGIN" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$2" == --theme && "$3" == jupiter ]] || exit 60
for member in install.json orm-group.svg orm-feature.svg; do
    tar -tzf "$1" | grep -Fxq "$member" || exit 61
done
printf 'installed\n' >"$TEST_PLUGIN_STATE"
MOCK
    cat >"$ORM_UNINSTALL_PLUGIN" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$2" == --theme=jupiter ]] || exit 62
rm -f -- "$TEST_PLUGIN_STATE"
MOCK
    cat >"$ORM_IS_REGISTERED" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
cat -- "$TEST_APPCONFIG_STATE"
MOCK
    cat >"$ORM_REGISTER_APPCONFIG" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == "$TEST_PACKAGE_APPCONFIG" ]] || exit 68
cp -- "$1" "$ORM_APPCONFIG"
printf '\nname=open_redis_manager\n' >>"$ORM_APPCONFIG"
chmod 0600 -- "$ORM_APPCONFIG"
printf '1\n' >"$TEST_APPCONFIG_STATE"
if [[ "$TEST_FAIL_REGISTER" == 1 ]]; then exit 63; fi
MOCK
    cat >"$ORM_UNREGISTER_APPCONFIG" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == open_redis_manager ]] || exit 64
rm -f -- "$ORM_APPCONFIG"
printf '0\n' >"$TEST_APPCONFIG_STATE"
MOCK
    cat >"$ORM_SYSTEMCTL" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
    list-unit-files) exit 0 ;;
    daemon-reload) exit 0 ;;
    enable)
        [[ "$2" == --now && "$3" == orm-broker.service ]] || exit 65
        printf 'enabled\n' >"$TEST_SYSTEMCTL_STATE.enabled"
        printf 'active\n' >"$TEST_SYSTEMCTL_STATE.active"
        ;;
    disable)
        [[ "$2" == --now && "$3" == orm-broker.service ]] || exit 66
        printf 'disabled\n' >"$TEST_SYSTEMCTL_STATE.enabled"
        printf 'inactive\n' >"$TEST_SYSTEMCTL_STATE.active"
        ;;
    *) exit 67 ;;
esac
MOCK
    chmod 0755 "$test_root/bin/"*
}

write_installer_runner() {
    local runner="$TEST_ROOT/run-installer.sh"
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf 'source %q\n' "$repo_root/packaging/lib.sh"
        printf 'export TEST_ROOT=%q\nexport TEST_TMPDIR=%q\nexport TEST_PLUGIN_STATE=%q\nexport TEST_APPCONFIG_STATE=%q\nexport TEST_SYSTEMCTL_STATE=%q\nexport TEST_PACKAGE_APPCONFIG=%q\n' \
            "$TEST_ROOT" "$TEST_TMPDIR" "$TEST_PLUGIN_STATE" "$TEST_APPCONFIG_STATE" "$TEST_SYSTEMCTL_STATE" "$TEST_PACKAGE_APPCONFIG"
        printf 'export TMPDIR=%q\nexport PATH=%q\n' "$TMPDIR" "$PATH"
        printf 'export ORM_CPANEL_ROOT=%q\nexport ORM_INSTALL_PLUGIN=%q\nexport ORM_UNINSTALL_PLUGIN=%q\n' \
            "$ORM_CPANEL_ROOT" "$ORM_INSTALL_PLUGIN" "$ORM_UNINSTALL_PLUGIN"
        printf 'export ORM_REGISTER_APPCONFIG=%q\nexport ORM_UNREGISTER_APPCONFIG=%q\nexport ORM_IS_REGISTERED=%q\n' \
            "$ORM_REGISTER_APPCONFIG" "$ORM_UNREGISTER_APPCONFIG" "$ORM_IS_REGISTERED"
        printf 'export ORM_CPanel_THEME=%q\nexport ORM_CPanel_LIVE=%q\nexport ORM_WHM_CGI=%q\nexport ORM_WHM_ICONS=%q\nexport ORM_3RDPARTY=%q\n' \
            "$ORM_CPanel_THEME" "$ORM_CPanel_LIVE" "$ORM_WHM_CGI" "$ORM_WHM_ICONS" "$ORM_3RDPARTY"
        printf 'export ORM_INSTALL_MANIFEST=%q\nexport ORM_APPCONFIG=%q\nexport ORM_LIFECYCLE_LOCK=%q\nexport ORM_SYSTEMCTL=%q\n' \
            "$ORM_INSTALL_MANIFEST" "$ORM_APPCONFIG" "$ORM_LIFECYCLE_LOCK" "$ORM_SYSTEMCTL"
        printf 'export ORM_BROKER_BIN=%q\nexport ORM_BROKER_LIB=%q\nexport ORM_BROKER_UNIT=%q\n' \
            "$ORM_BROKER_BIN" "$ORM_BROKER_LIB" "$ORM_BROKER_UNIT"
        printf 'export ORM_INSTANCE_ROOT=%q\nexport ORM_INSTANCE_DATA=%q\nexport ORM_INSTANCE_UNIT=%q\n' \
            "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA" "$ORM_INSTANCE_UNIT"
        printf 'export ORM_INSTANCE_LAUNCHER=%q\nexport ORM_METRICS_COLLECTOR=%q\nexport ORM_METRICS_SERVICE=%q\n' \
            "$ORM_INSTANCE_LAUNCHER" "$ORM_METRICS_COLLECTOR" "$ORM_METRICS_SERVICE"
        printf 'export ORM_METRICS_TIMER=%q\nexport ORM_BROKER_SOCKET=%q\n' "$ORM_METRICS_TIMER" "$ORM_BROKER_SOCKET"
        printf 'export TEST_FAIL_REGISTER=%q\n' "$TEST_FAIL_REGISTER"
        cat <<'MOCK'
orm_require_root_and_platform() {
    [[ "$(id -u)" -eq 0 ]] || orm_die 'test runner must be root.'
    local path key source target mode
    for path in "$ORM_CPANEL_ROOT" "$ORM_INSTALL_PLUGIN" "$ORM_UNINSTALL_PLUGIN" "$ORM_REGISTER_APPCONFIG" \
        "$ORM_UNREGISTER_APPCONFIG" "$ORM_IS_REGISTERED" "$ORM_APPCONFIG" "$ORM_INSTALL_MANIFEST" \
        "$ORM_LIFECYCLE_LOCK" "$ORM_SYSTEMCTL" "$ORM_BROKER_SOCKET" \
        "$ORM_BROKER_UNIT" "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA" "$ORM_INSTANCE_UNIT" \
        "$ORM_METRICS_SERVICE" "$ORM_METRICS_TIMER"; do
        [[ "$path" == "$TEST_ROOT/"* ]] || orm_die "test target escaped its isolated root: $path"
    done
    while IFS='|' read -r key source target mode; do
        [[ "$target" == "$TEST_ROOT/"* ]] || orm_die "installer target escaped its isolated root: $target"
    done < <(orm_package_file_map)
}
MOCK
        tail -n +4 "$repo_root/packaging/install.sh"
    } >"$runner"
    chmod 0755 "$runner"
}

configure_case success
TEST_FAIL_REGISTER=0
export TEST_FAIL_REGISTER
write_installer_runner
bash "$TEST_ROOT/run-installer.sh"
orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" || { printf 'fresh install manifest did not validate.\n' >&2; exit 1; }
[[ "$(cat "$TEST_PLUGIN_STATE")" == installed && "$(cat "$TEST_APPCONFIG_STATE")" == 1 ]] \
    || { printf 'fresh install did not register cPanel and WHM entries.\n' >&2; exit 1; }
orm_appconfig_matches_package "$ORM_APPCONFIG" || { printf 'fresh install AppConfig does not match the package.\n' >&2; exit 1; }
[[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == enabled && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == active ]] \
    || { printf 'fresh install did not enable and start the broker.\n' >&2; exit 1; }
for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
    [[ -d "$path" && ! -L "$path" && "$(stat -c '%u:%a' "$path")" == 0:711 ]] \
        || { printf 'fresh install did not prepare a private root: %s\n' "$path" >&2; exit 1; }
done
[[ -z "$(find "$TEST_TMPDIR" -mindepth 1 -print -quit)" ]] || { printf 'fresh install left its temporary archive behind.\n' >&2; exit 1; }

configure_case register-failure
TEST_FAIL_REGISTER=1
export TEST_FAIL_REGISTER
write_installer_runner
if bash "$TEST_ROOT/run-installer.sh"; then
    printf 'expected the injected WHM registration failure to stop installation.\n' >&2
    exit 1
fi
[[ ! -e "$TEST_PLUGIN_STATE" && "$(cat "$TEST_APPCONFIG_STATE")" == 0 && ! -e "$ORM_APPCONFIG" ]] \
    || { printf 'installer rollback left cPanel or WHM registration behind.\n' >&2; exit 1; }
[[ "$(cat "$TEST_SYSTEMCTL_STATE.enabled")" == disabled && "$(cat "$TEST_SYSTEMCTL_STATE.active")" == inactive ]] \
    || { printf 'installer rollback did not stop and disable the broker.\n' >&2; exit 1; }
[[ ! -e "$ORM_INSTALL_MANIFEST" && ! -e "$ORM_INSTANCE_ROOT" && ! -e "$ORM_INSTANCE_DATA" ]] \
    || { printf 'installer rollback left a manifest or runtime root behind.\n' >&2; exit 1; }
while IFS='|' read -r key source target mode; do
    [[ ! -e "$target" && ! -L "$target" ]] || { printf 'installer rollback left %s behind.\n' "$key" >&2; exit 1; }
done < <(orm_package_file_map)
[[ -z "$(find "$TEST_TMPDIR" -mindepth 1 -print -quit)" ]] || { printf 'installer rollback left its temporary archive behind.\n' >&2; exit 1; }

printf 'Open Redis Manager fresh install and rollback passed in isolated mock cPanel roots.\n'
