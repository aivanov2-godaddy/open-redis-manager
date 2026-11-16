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
ORM_INSTALL_MANIFEST="$ORM_3RDPARTY/install-manifest"
ORM_APPCONFIG=/var/cpanel/apps/open_redis_manager.conf
ORM_LIFECYCLE_LOCK=/run/lock/orm-lifecycle.lock
ORM_BROKER_SOCKET=/run/orm/broker.sock
ORM_PERL=/usr/bin/perl
ORM_SYSTEMCTL=/usr/bin/systemctl
ORM_BROKER_BIN="$ORM_3RDPARTY/bin/orm-broker.pl"
ORM_BROKER_LIB="$ORM_3RDPARTY/lib/Orm/Broker"
ORM_BROKER_UNIT=/etc/systemd/system/orm-broker.service
ORM_INSTANCE_ROOT=/etc/orm-instances
ORM_INSTANCE_DATA=/var/lib/orm-instances
ORM_INSTANCE_UNIT=/etc/systemd/system/orm-instance@.service
ORM_INSTANCE_LAUNCHER="$ORM_3RDPARTY/bin/orm-instance-launcher"
ORM_METRICS_COLLECTOR="$ORM_3RDPARTY/bin/orm-metrics-collect.pl"
ORM_METRICS_SERVICE=/etc/systemd/system/orm-metrics-collect@.service
ORM_METRICS_TIMER=/etc/systemd/system/orm-metrics-collect@.timer

orm_die() { printf 'ORM installer: %s\n' "$*" >&2; exit 1; }

orm_acquire_lifecycle_lock() {
    command -v flock >/dev/null 2>&1 || orm_die 'flock is required to serialize ORM package operations.'
    [[ ! -L "$ORM_LIFECYCLE_LOCK" && ! -d "$ORM_LIFECYCLE_LOCK" ]] \
        || orm_die 'the ORM lifecycle lock path is unsafe.'
    install -d -o root -g root -m 0755 "$(dirname -- "$ORM_LIFECYCLE_LOCK")"
    exec 9>>"$ORM_LIFECYCLE_LOCK"
    flock -n 9 || orm_die 'another ORM install, upgrade, or uninstall is already running.'
}

orm_safe_target_parent_chain() {
    local parent="$(dirname -- "$1")"
    while [[ "$parent" != / ]]; do
        [[ ! -L "$parent" && ( ! -e "$parent" || -d "$parent" ) ]] || return 1
        parent="$(dirname -- "$parent")"
    done
}

orm_package_file_map() {
    printf '%s|%s|%s|%s\n' \
        cpanel_entry "$ORM_PACKAGE_ROOT/cpanel/files/orm/index.live.php" "$ORM_CPanel_LIVE/index.live.php" 644 \
        whm_cgi "$ORM_PACKAGE_ROOT/whm/cgi/addon_open_redis_manager.php" "$ORM_WHM_CGI/addon_open_redis_manager.php" 644 \
        whm_icon "$ORM_PACKAGE_ROOT/whm/icons/orm-whm.png" "$ORM_WHM_ICONS/orm-whm.png" 644 \
        backend_discovery "$ORM_REPO_ROOT/src/Orm/Backend/BackendDiscovery.php" "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php" 644 \
        whm_acl "$ORM_REPO_ROOT/src/Orm/Security/WhmAcl.php" "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php" 644 \
        session_request_guard "$ORM_REPO_ROOT/src/Orm/Security/SessionRequestGuard.php" "$ORM_3RDPARTY/src/Orm/Security/SessionRequestGuard.php" 644 \
        account_context "$ORM_REPO_ROOT/src/Orm/Cpanel/AuthenticatedAccountContext.php" "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php" 644 \
        broker_identity "$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerIdentityVerifier.php" "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php" 644 \
        broker_client "$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerClient.php" "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerClient.php" 644 \
        connection_details "$ORM_REPO_ROOT/src/Orm/Cpanel/ConnectionDetails.php" "$ORM_3RDPARTY/src/Orm/Cpanel/ConnectionDetails.php" 644 \
        diagnostic_report "$ORM_REPO_ROOT/src/Orm/Cpanel/DiagnosticReport.php" "$ORM_3RDPARTY/src/Orm/Cpanel/DiagnosticReport.php" 644 \
        backend_policy_store "$ORM_REPO_ROOT/src/Orm/Backend/BackendPolicyStore.php" "$ORM_3RDPARTY/src/Orm/Backend/BackendPolicyStore.php" 644 \
        broker_bin "$ORM_REPO_ROOT/bin/orm-broker.pl" "$ORM_BROKER_BIN" 755 \
        instance_launcher "$ORM_REPO_ROOT/bin/orm-instance-launcher.pl" "$ORM_INSTANCE_LAUNCHER" 755 \
        metrics_collector "$ORM_REPO_ROOT/bin/orm-metrics-collect.pl" "$ORM_METRICS_COLLECTOR" 755 \
        broker_account_resolver "$ORM_REPO_ROOT/src/Orm/Broker/AccountResolver.pm" "$ORM_BROKER_LIB/AccountResolver.pm" 644 \
        broker_backend_policy "$ORM_REPO_ROOT/src/Orm/Broker/BackendPolicy.pm" "$ORM_BROKER_LIB/BackendPolicy.pm" 644 \
        broker_handler "$ORM_REPO_ROOT/src/Orm/Broker/Handler.pm" "$ORM_BROKER_LIB/Handler.pm" 644 \
        broker_instance_manager "$ORM_REPO_ROOT/src/Orm/Broker/InstanceManager.pm" "$ORM_BROKER_LIB/InstanceManager.pm" 644 \
        broker_fleet_inventory "$ORM_REPO_ROOT/src/Orm/Broker/FleetInventory.pm" "$ORM_BROKER_LIB/FleetInventory.pm" 644 \
        broker_peer_credentials "$ORM_REPO_ROOT/src/Orm/Broker/PeerCredentials.pm" "$ORM_BROKER_LIB/PeerCredentials.pm" 644 \
        broker_protocol "$ORM_REPO_ROOT/src/Orm/Broker/Protocol.pm" "$ORM_BROKER_LIB/Protocol.pm" 644 \
        broker_server "$ORM_REPO_ROOT/src/Orm/Broker/Server.pm" "$ORM_BROKER_LIB/Server.pm" 644 \
        broker_unit "$ORM_PACKAGE_ROOT/systemd/orm-broker.service" "$ORM_BROKER_UNIT" 644 \
        instance_unit "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" "$ORM_INSTANCE_UNIT" 644 \
        metrics_service "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.service" "$ORM_METRICS_SERVICE" 644 \
        metrics_timer "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.timer" "$ORM_METRICS_TIMER" 644 \
        whm_appconfig "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" "$ORM_APPCONFIG" 600
}

orm_legacy_identity_v1_file_map() {
    local key source target mode
    while IFS='|' read -r key source target mode; do
        case "$key" in
            cpanel_entry|whm_cgi|whm_icon|backend_discovery|whm_acl|account_context|broker_identity|broker_bin|broker_account_resolver|broker_handler|broker_peer_credentials|broker_protocol|broker_server|broker_unit|whm_appconfig)
                printf '%s|%s|%s\n' "$key" "$target" "$mode"
                ;;
        esac
    done < <(orm_package_file_map)
}

orm_validate_legacy_identity_v1() {
    local manifest="$ORM_PACKAGE_ROOT/legacy/identity-v1/install.manifest"
    local key target mode expected_mode expected_digest actual_digest file_owner
    local -A recorded=() expected=()
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    [[ "$(head -n 1 -- "$manifest")" == orm-identity-install-v1 ]] || return 1
    while IFS='|' read -r key mode expected_digest; do
        [[ "$key" =~ ^[a-z_]+$ && "$mode" =~ ^[0-7]{3,4}$ && "$expected_digest" =~ ^[a-f0-9]{64}$ ]] || return 1
        [[ -z "${recorded[$key]+present}" ]] || return 1
        recorded[$key]="$mode|$expected_digest"
    done < <(tail -n +2 -- "$manifest")
    while IFS='|' read -r key target mode; do
        expected[$key]=1
        orm_safe_target_parent_chain "$target" || return 1
        [[ -n "${recorded[$key]+present}" && -f "$target" && ! -L "$target" ]] || return 1
        file_owner="$(stat -c '%u' -- "$target")" || return 1
        [[ "$file_owner" == 0 ]] || return 1
        IFS='|' read -r expected_mode expected_digest <<<"${recorded[$key]}"
        [[ "$expected_mode" == "$mode" && "$(stat -c '%a' -- "$target")" == "$mode" ]] || return 1
        actual_digest="$(sha256sum -- "$target" | awk '{print $1}')" || return 1
        [[ "$actual_digest" == "$expected_digest" ]] || return 1
    done < <(orm_legacy_identity_v1_file_map)
    [[ "${#recorded[@]}" -eq "${#expected[@]}" ]]
}

orm_write_install_manifest() {
    local destination="$1" key source target mode digest owner temporary
    temporary="${destination}.tmp.$$"
    (umask 077; printf 'orm-install-manifest-v1\n' >"$temporary") \
        || orm_die 'could not create the ORM install manifest.'
    while IFS='|' read -r key source target mode; do
        [[ -f "$target" && ! -L "$target" ]] || orm_die "cannot manifest an unsafe installed file: $target"
        owner="$(stat -c '%u' -- "$target")" || orm_die "could not verify installed file owner: $target"
        [[ "$owner" == 0 ]] || orm_die "installed file is not root-owned: $target"
        [[ "$(stat -c '%a' -- "$target")" == "$mode" ]] || orm_die "installed file mode does not match the package: $target"
        digest="$(sha256sum -- "$target" | awk '{print $1}')" || orm_die "could not hash installed file: $target"
        printf '%s|%s|%s\n' "$key" "$mode" "$digest" >>"$temporary"
    done < <(orm_package_file_map)
    chmod 0600 -- "$temporary"
    chown root:root -- "$temporary"
    mv -f -- "$temporary" "$destination"
}

orm_validate_install_manifest() {
    local manifest="$1" key source target mode expected_digest actual_digest owner manifest_mode file_owner
    local -A recorded=() expected=()
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    owner="$(stat -c '%u' -- "$manifest")" || return 1
    manifest_mode="$(stat -c '%a' -- "$manifest")" || return 1
    [[ "$owner" == 0 && "$manifest_mode" == 600 ]] || return 1
    [[ "$(head -n 1 -- "$manifest")" == orm-install-manifest-v1 ]] || return 1
    while IFS='|' read -r key mode expected_digest; do
        [[ "$key" =~ ^[a-z_]+$ && "$mode" =~ ^[0-7]{3,4}$ && "$expected_digest" =~ ^[a-f0-9]{64}$ ]] || return 1
        [[ -z "${recorded[$key]+present}" ]] || return 1
        recorded[$key]="$mode|$expected_digest"
    done < <(tail -n +2 -- "$manifest")
    while IFS='|' read -r key source target mode; do
        expected[$key]=1
        orm_safe_target_parent_chain "$target" || return 1
        [[ -n "${recorded[$key]+present}" ]] || return 1
        IFS='|' read -r expected_mode expected_digest <<<"${recorded[$key]}"
        [[ "$expected_mode" == "$mode" && -f "$target" && ! -L "$target" ]] || return 1
        file_owner="$(stat -c '%u' -- "$target")" || return 1
        [[ "$file_owner" == 0 ]] || return 1
        [[ "$(stat -c '%a' -- "$target")" == "$mode" ]] || return 1
        actual_digest="$(sha256sum -- "$target" | awk '{print $1}')" || return 1
        [[ "$actual_digest" == "$expected_digest" ]] || return 1
    done < <(orm_package_file_map)
    [[ "${#recorded[@]}" -eq "${#expected[@]}" ]]
}

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
    if ! mkdir -p "$stage/orm" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/install.json" "$stage/orm/install.json" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-group.svg" "$stage/orm/orm-group.svg" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-feature.svg" "$stage/orm/orm-feature.svg" \
        || ! tar -czf "$destination" -C "$stage/orm" install.json orm-group.svg orm-feature.svg; then
        rm -rf -- "$stage"
        return 1
    fi
    rm -rf -- "$stage"
}

orm_make_legacy_identity_v1_cpanel_archive() {
    local destination="$1" legacy="$ORM_PACKAGE_ROOT/legacy/identity-v1/cpanel" stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/orm-cpanel-legacy.XXXXXXXX")"
    if ! mkdir -p "$stage/orm" \
        || ! install -m 0644 "$legacy/install.json" "$stage/orm/install.json" \
        || ! install -m 0644 "$legacy/icons/orm-group.svg" "$stage/orm/orm-group.svg" \
        || ! install -m 0644 "$legacy/icons/orm-feature.svg" "$stage/orm/orm-feature.svg" \
        || ! tar -czf "$destination" -C "$stage/orm" install.json orm-group.svg orm-feature.svg; then
        rm -rf -- "$stage"
        return 1
    fi
    rm -rf -- "$stage"
}

orm_registration_state() {
    local result
    result="$("$ORM_IS_REGISTERED" whostmgr open_redis_manager 2>/dev/null)" || return 2
    case "$result" in
        1) return 0 ;;
        0) return 1 ;;
        *) return 2 ;;
    esac
}

orm_install_paths_are_clear() {
    local path unit_state source target mode key
    while IFS='|' read -r key source target mode; do
        orm_safe_target_parent_chain "$target" || orm_die "refusing an unsafe target directory: $(dirname -- "$target")"
        [[ ! -e "$target" && ! -L "$target" ]] || orm_die "refusing to overwrite existing path: $target"
    done < <(orm_package_file_map)
    path="$ORM_INSTALL_MANIFEST"
    [[ ! -e "$path" && ! -L "$path" ]] || orm_die "refusing to overwrite existing path: $path"
    path="$ORM_APPCONFIG"
    [[ ! -e "$path" && ! -L "$path" ]] || orm_die "refusing to overwrite existing path: $path"
    [[ ! -e "$ORM_INSTANCE_ROOT" && ! -L "$ORM_INSTANCE_ROOT" ]] \
        || orm_die "refusing to use an existing instance metadata path: $ORM_INSTANCE_ROOT"
    [[ ! -e "$ORM_INSTANCE_DATA" && ! -L "$ORM_INSTANCE_DATA" ]] \
        || orm_die "refusing to use an existing instance data path: $ORM_INSTANCE_DATA"
    unit_state="$("$ORM_SYSTEMCTL" list-unit-files --no-legend --no-pager orm-broker.service 2>/dev/null || true)"
    [[ -z "$unit_state" ]] || orm_die 'an orm-broker.service unit already exists; refusing to replace it.'
    if orm_registration_state; then
        orm_die 'the WHM AppConfig application is already registered.'
    else
        local registration_status=$?
        [[ "$registration_status" -eq 1 ]] || orm_die 'could not safely verify WHM AppConfig registration.'
    fi
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
    local source target mode key
    while IFS='|' read -r key source target mode; do
        [[ ! -e "$target" ]] && continue
        [[ -f "$target" && -f "$source" ]] || orm_die "refusing to remove an unexpected ORM path: $target"
        cmp -s -- "$source" "$target" || orm_die "installed file differs from this package; refusing removal: $target"
    done < <(orm_package_file_map)
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
        active) ;;
        inactive|failed) active=inactive ;;
        *) return 1 ;;
    esac
    ORM_BROKER_ENABLED_BEFORE="$enabled"
    ORM_BROKER_ACTIVE_BEFORE="$active"
}

orm_broker_state_matches_initial() {
    local enabled active
    enabled="$("$ORM_SYSTEMCTL" is-enabled orm-broker.service 2>/dev/null || true)"
    active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
    case "$active" in
        active) ;;
        inactive|failed) active=inactive ;;
        *) return 1 ;;
    esac
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
        inactive) "$ORM_SYSTEMCTL" stop orm-broker.service || return 1 ;;
        *) return 1 ;;
    esac
}
