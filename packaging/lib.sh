#!/usr/bin/env bash
set -Eeuo pipefail

ORM_PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ORM_REPO_ROOT="$(cd -- "$ORM_PACKAGE_ROOT/.." && pwd -P)"
ORM_CPANEL_ROOT=/usr/local/cpanel
ORM_CPanel_THEME=jupiter
ORM_INSTALL_PLUGIN="$ORM_CPANEL_ROOT/scripts/install_plugin"
ORM_UNINSTALL_PLUGIN="$ORM_CPANEL_ROOT/scripts/uninstall_plugin"
ORM_REGISTER_APPCONFIG="$ORM_CPANEL_ROOT/bin/register_appconfig"
ORM_UNREGISTER_APPCONFIG="$ORM_CPANEL_ROOT/bin/unregister_appconfig"
ORM_IS_REGISTERED="$ORM_CPANEL_ROOT/bin/is_registered_with_appconfig"
ORM_CPanel_LIVE="$ORM_CPANEL_ROOT/base/frontend/$ORM_CPanel_THEME/orm"
ORM_WHM_CGI="$ORM_CPANEL_ROOT/whostmgr/docroot/cgi"
ORM_WHM_ICONS="$ORM_CPANEL_ROOT/whostmgr/docroot/addon_plugins"
ORM_3RDPARTY="$ORM_CPANEL_ROOT/3rdparty/orm"
ORM_APPCONFIG=/var/cpanel/apps/open_redis_manager.conf
ORM_PERL=/usr/bin/perl
ORM_SYSTEMCTL=/usr/bin/systemctl
ORM_BROKER_BIN="$ORM_3RDPARTY/bin/orm-broker.pl"
ORM_BROKER_LIB="$ORM_3RDPARTY/lib/Orm/Broker"
ORM_BROKER_UNIT=/etc/systemd/system/orm-broker.service
ORM_INSTANCE_ROOT=/etc/orm-instances
ORM_INSTANCE_DATA=/var/lib/orm-instances
ORM_INSTANCE_UNIT=/etc/systemd/system/orm-instance@.service
ORM_INSTANCE_LAUNCHER="$ORM_3RDPARTY/bin/orm-instance-launcher"

orm_die() { printf 'ORM installer: %s\n' "$*" >&2; exit 1; }

orm_require_root_and_platform() {
    [[ "$(id -u)" -eq 0 ]] || orm_die 'run this script as root.'
    [[ "$(uname -s)" == Linux ]] || orm_die 'cPanel & WHM installation is supported only on Linux.'
    [[ -x "$ORM_INSTALL_PLUGIN" && -x "$ORM_UNINSTALL_PLUGIN" ]] || orm_die 'cPanel plugin lifecycle scripts were not found.'
    [[ -x "$ORM_REGISTER_APPCONFIG" && -x "$ORM_UNREGISTER_APPCONFIG" && -x "$ORM_IS_REGISTERED" ]] || orm_die 'WHM AppConfig lifecycle scripts were not found.'
    [[ -x "$ORM_PERL" && -x "$ORM_SYSTEMCTL" ]] || orm_die 'Perl or systemd is required for the ORM identity broker.'
    [[ -f "$ORM_CPANEL_ROOT/php/WHM.php" && -f "$ORM_CPANEL_ROOT/php/cpanel.php" ]] || orm_die 'expected cPanel PHP interface files were not found.'
}

orm_make_cpanel_archive() {
    local destination="$1"
    local stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/orm-cpanel.XXXXXXXX")"
    mkdir -p "$stage/orm"
    install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/install.json" "$stage/orm/install.json"
    install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-group.svg" "$stage/orm/orm-group.svg"
    install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-feature.svg" "$stage/orm/orm-feature.svg"
    tar -czf "$destination" -C "$stage/orm" install.json orm-group.svg orm-feature.svg
    rm -rf -- "$stage"
}

orm_registration_state() {
    local result
    result="$("$ORM_IS_REGISTERED" whostmgr open_redis_manager 2>/dev/null || true)"
    [[ "$result" == 1 ]]
}

orm_install_paths_are_clear() {
    local path unit_state
    for path in \
        "$ORM_CPanel_LIVE/index.live.php" \
        "$ORM_WHM_CGI/addon_open_redis_manager.php" \
        "$ORM_WHM_ICONS/orm-whm.png" \
        "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php" \
        "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php" \
        "$ORM_3RDPARTY/src/Orm/Security/SessionRequestGuard.php" \
        "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php" \
        "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php" \
        "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerClient.php" \
        "$ORM_3RDPARTY/src/Orm/Backend/BackendPolicyStore.php" \
        "$ORM_BROKER_BIN" \
        "$ORM_INSTANCE_LAUNCHER" \
        "$ORM_BROKER_LIB/AccountResolver.pm" \
        "$ORM_BROKER_LIB/BackendPolicy.pm" \
        "$ORM_BROKER_LIB/Handler.pm" \
        "$ORM_BROKER_LIB/InstanceManager.pm" \
        "$ORM_BROKER_LIB/PeerCredentials.pm" \
        "$ORM_BROKER_LIB/Protocol.pm" \
        "$ORM_BROKER_LIB/Server.pm" \
        "$ORM_BROKER_UNIT" \
        "$ORM_INSTANCE_UNIT" \
        "$ORM_APPCONFIG"; do
        [[ ! -e "$path" && ! -L "$path" ]] || orm_die "refusing to overwrite existing path: $path"
    done
    [[ ! -e "$ORM_INSTANCE_ROOT" && ! -L "$ORM_INSTANCE_ROOT" ]] \
        || orm_die "refusing to use an existing instance metadata path: $ORM_INSTANCE_ROOT"
    [[ ! -e "$ORM_INSTANCE_DATA" && ! -L "$ORM_INSTANCE_DATA" ]] \
        || orm_die "refusing to use an existing instance data path: $ORM_INSTANCE_DATA"
    unit_state="$("$ORM_SYSTEMCTL" list-unit-files --no-legend --no-pager orm-broker.service 2>/dev/null || true)"
    [[ -z "$unit_state" ]] || orm_die 'an orm-broker.service unit already exists; refusing to replace it.'
    ! orm_registration_state || orm_die 'the WHM AppConfig application is already registered.'
}

orm_prepare_instance_directories() {
    local path owner mode
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        if [[ ! -e "$path" && ! -L "$path" ]]; then
            mkdir -m 0711 -- "$path" || orm_die "could not create the ORM runtime directory: $path"
            chown root:root -- "$path" || orm_die "could not secure the ORM runtime directory: $path"
            chmod 0711 -- "$path" || orm_die "could not set private traversal permissions on: $path"
            continue
        fi
        [[ -d "$path" && ! -L "$path" ]] || orm_die "refusing an unsafe ORM runtime path: $path"
        owner="$(stat -c '%u' -- "$path")"
        mode="$(stat -c '%a' -- "$path")"
        [[ "$owner" == 0 ]] || orm_die "the ORM runtime directory is not root-owned: $path"
        (( (8#$mode & 0022) == 0 )) || orm_die "the ORM runtime directory is writable by another user: $path"
        chmod 0711 -- "$path" || orm_die "could not set private traversal permissions on: $path"
    done
}

orm_remove_empty_owned_directories() {
    local path
    for path in \
        "$ORM_INSTANCE_ROOT" \
        "$ORM_INSTANCE_DATA" \
        "$ORM_3RDPARTY/src/Orm/Backend" \
        "$ORM_3RDPARTY/src/Orm/Security" \
        "$ORM_3RDPARTY/src/Orm/Cpanel" \
        "$ORM_BROKER_LIB" \
        "$ORM_3RDPARTY/lib/Orm" \
        "$ORM_3RDPARTY/lib" \
        "$ORM_3RDPARTY/bin" \
        "$ORM_3RDPARTY/src/Orm" \
        "$ORM_3RDPARTY/src" \
        "$ORM_3RDPARTY" \
        "$ORM_CPanel_LIVE"; do
        rmdir -- "$path" 2>/dev/null || true
    done
}

orm_verify_installed_files() {
    local source target
    while IFS='|' read -r source target; do
        [[ ! -e "$target" ]] && continue
        [[ -f "$target" && -f "$source" ]] || orm_die "refusing to remove an unexpected ORM path: $target"
        cmp -s -- "$source" "$target" || orm_die "installed file differs from this package; refusing removal: $target"
    done <<EOF
$ORM_PACKAGE_ROOT/cpanel/files/orm/index.live.php|$ORM_CPanel_LIVE/index.live.php
$ORM_PACKAGE_ROOT/whm/cgi/addon_open_redis_manager.php|$ORM_WHM_CGI/addon_open_redis_manager.php
$ORM_PACKAGE_ROOT/whm/icons/orm-whm.png|$ORM_WHM_ICONS/orm-whm.png
$ORM_REPO_ROOT/src/Orm/Backend/BackendDiscovery.php|$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php
$ORM_REPO_ROOT/src/Orm/Security/WhmAcl.php|$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php
$ORM_REPO_ROOT/src/Orm/Security/SessionRequestGuard.php|$ORM_3RDPARTY/src/Orm/Security/SessionRequestGuard.php
$ORM_REPO_ROOT/src/Orm/Cpanel/AuthenticatedAccountContext.php|$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php
$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerIdentityVerifier.php|$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php
$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerClient.php|$ORM_3RDPARTY/src/Orm/Cpanel/BrokerClient.php
$ORM_REPO_ROOT/src/Orm/Backend/BackendPolicyStore.php|$ORM_3RDPARTY/src/Orm/Backend/BackendPolicyStore.php
$ORM_REPO_ROOT/bin/orm-broker.pl|$ORM_BROKER_BIN
$ORM_REPO_ROOT/bin/orm-instance-launcher.pl|$ORM_INSTANCE_LAUNCHER
$ORM_REPO_ROOT/src/Orm/Broker/AccountResolver.pm|$ORM_BROKER_LIB/AccountResolver.pm
$ORM_REPO_ROOT/src/Orm/Broker/BackendPolicy.pm|$ORM_BROKER_LIB/BackendPolicy.pm
$ORM_REPO_ROOT/src/Orm/Broker/Handler.pm|$ORM_BROKER_LIB/Handler.pm
$ORM_REPO_ROOT/src/Orm/Broker/InstanceManager.pm|$ORM_BROKER_LIB/InstanceManager.pm
$ORM_REPO_ROOT/src/Orm/Broker/PeerCredentials.pm|$ORM_BROKER_LIB/PeerCredentials.pm
$ORM_REPO_ROOT/src/Orm/Broker/Protocol.pm|$ORM_BROKER_LIB/Protocol.pm
$ORM_REPO_ROOT/src/Orm/Broker/Server.pm|$ORM_BROKER_LIB/Server.pm
$ORM_PACKAGE_ROOT/systemd/orm-broker.service|$ORM_BROKER_UNIT
$ORM_PACKAGE_ROOT/systemd/orm-instance@.service|$ORM_INSTANCE_UNIT
EOF
}

orm_instances_exist() {
    local path entries owner mode
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        [[ -d "$path" && ! -L "$path" ]] || return 2
        owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 2
        mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 2
        [[ "$owner" == 0 && "$mode" == 711 ]] || return 2
        entries="$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" || return 2
        [[ -z "$entries" ]] || return 0
    done
    return 1
}

orm_capture_broker_state() {
    local enabled active
    enabled="$("$ORM_SYSTEMCTL" is-enabled orm-broker.service 2>/dev/null || true)"
    active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
    case "$enabled" in
        enabled|disabled|enabled-runtime) ;;
        *) return 1 ;;
    esac
    case "$active" in
        active|inactive|failed) ;;
        *) return 1 ;;
    esac
    ORM_BROKER_ENABLED_BEFORE="$enabled"
    ORM_BROKER_ACTIVE_BEFORE="$active"
}

orm_broker_state_matches_initial() {
    local enabled active
    enabled="$("$ORM_SYSTEMCTL" is-enabled orm-broker.service 2>/dev/null || true)"
    active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
    [[ "$enabled" == "${ORM_BROKER_ENABLED_BEFORE:-}" \
        && "$active" == "${ORM_BROKER_ACTIVE_BEFORE:-}" ]]
}

orm_restore_broker_state() {
    case "${ORM_BROKER_ENABLED_BEFORE:-}" in
        enabled) "$ORM_SYSTEMCTL" enable orm-broker.service || return 1 ;;
        disabled) "$ORM_SYSTEMCTL" disable orm-broker.service || return 1 ;;
        enabled-runtime) "$ORM_SYSTEMCTL" enable --runtime orm-broker.service || return 1 ;;
        *) return 1 ;;
    esac
    case "${ORM_BROKER_ACTIVE_BEFORE:-}" in
        active) "$ORM_SYSTEMCTL" start orm-broker.service || return 1 ;;
        inactive|failed) "$ORM_SYSTEMCTL" stop orm-broker.service || return 1 ;;
        *) return 1 ;;
    esac
}
