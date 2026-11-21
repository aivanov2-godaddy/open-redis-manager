#!/usr/bin/env bash
set -Eeuo pipefail

ORM_PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ORM_REPO_ROOT="$(cd -- "$ORM_PACKAGE_ROOT/.." && pwd -P)"
ORM_VERSION_FILE="$ORM_REPO_ROOT/VERSION"
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
ORM_PROVIDER_EVENTS_CONFIG=/etc/orm-provider-events.json
ORM_PROVIDER_EVENTS_ROOT=/var/lib/orm-events
ORM_PROVIDER_EVENTS_OUTBOX="$ORM_PROVIDER_EVENTS_ROOT/outbox"
ORM_PROVIDER_EVENTS_SERVICE=/etc/systemd/system/orm-provider-events.service
ORM_PROVIDER_EVENTS_TIMER=/etc/systemd/system/orm-provider-events.timer
ORM_CREATED_INSTANCE_ROOTS=()
ORM_CREATED_PROVIDER_EVENT_PATHS=()

orm_die() { printf 'ORM installer: %s\n' "$*" >&2; exit 1; }

orm_refresh_cpanel_icon_sprite_cache_key() {
    local icon_root="$ORM_CPANEL_ROOT/base/frontend/$ORM_CPanel_THEME/assets/application_icons"
    local sprite="$icon_root/sprites/icon_spritemap.svg"
    local stylesheet="$icon_root/sprites/icon_spritemap.css"
    local digest current temporary sprite_mode stylesheet_mode sprite_generator sprite_generator_mode

    [[ -f "$sprite" && ! -L "$sprite" && -f "$stylesheet" && ! -L "$stylesheet" ]] || return 0
    orm_safe_root_owned_parent_chain "$sprite" && orm_safe_root_owned_parent_chain "$stylesheet" || {
        printf 'ORM installer: could not safely refresh the cPanel icon sprite cache key.\n' >&2
        return 0
    }
    sprite_mode="$(stat -c '%a' -- "$sprite" 2>/dev/null || true)"
    stylesheet_mode="$(stat -c '%a' -- "$stylesheet" 2>/dev/null || true)"
    [[ "$(stat -c '%u' -- "$sprite" 2>/dev/null || true)" == 0 \
        && "$(stat -c '%u' -- "$stylesheet" 2>/dev/null || true)" == 0 \
        && "$sprite_mode" =~ ^[0-7]{3,4}$ && "$stylesheet_mode" =~ ^[0-7]{3,4}$ ]] || {
        printf 'ORM installer: cPanel icon sprite files are not root-owned; leaving the cache key unchanged.\n' >&2
        return 0
    }
    (( (8#$sprite_mode & 0022) == 0 && (8#$stylesheet_mode & 0022) == 0 )) || {
        printf 'ORM installer: cPanel icon sprite files are writable by another user; leaving the cache key unchanged.\n' >&2
        return 0
    }

    # install_plugin schedules sprite generation, so it may rewrite the CSS
    # cache URL after this function returns. Generate the current theme's sprite
    # synchronously first, then key the CSS to the resulting SVG below.
    sprite_generator="$ORM_CPANEL_ROOT/bin/sprite_generator"
    if [[ -x "$sprite_generator" ]]; then
        orm_safe_root_owned_parent_chain "$sprite_generator" || {
            printf 'ORM installer: cPanel sprite generator path is unsafe; leaving the cache key unchanged.\n' >&2
            return 0
        }
        [[ -f "$sprite_generator" && ! -L "$sprite_generator" \
            && "$(stat -c '%u' -- "$sprite_generator" 2>/dev/null || true)" == 0 ]] || {
            printf 'ORM installer: cPanel sprite generator is not a root-owned regular file; leaving the cache key unchanged.\n' >&2
            return 0
        }
        sprite_generator_mode="$(stat -c '%a' -- "$sprite_generator" 2>/dev/null || true)"
        [[ "$sprite_generator_mode" =~ ^[0-7]{3,4}$ ]] \
            && (( (8#$sprite_generator_mode & 0022) == 0 )) || {
            printf 'ORM installer: cPanel sprite generator has unsafe permissions; leaving the cache key unchanged.\n' >&2
            return 0
        }
        if ! "$sprite_generator" --theme "$ORM_CPanel_THEME" >/dev/null 2>&1; then
            printf 'ORM installer: cPanel sprite generation failed; leaving the cache key unchanged.\n' >&2
            return 0
        fi
        [[ -f "$sprite" && ! -L "$sprite" && -f "$stylesheet" && ! -L "$stylesheet" ]] || return 0
        orm_safe_root_owned_parent_chain "$sprite" && orm_safe_root_owned_parent_chain "$stylesheet" || return 0
        sprite_mode="$(stat -c '%a' -- "$sprite" 2>/dev/null || true)"
        stylesheet_mode="$(stat -c '%a' -- "$stylesheet" 2>/dev/null || true)"
        [[ "$(stat -c '%u' -- "$sprite" 2>/dev/null || true)" == 0 \
            && "$(stat -c '%u' -- "$stylesheet" 2>/dev/null || true)" == 0 \
            && "$sprite_mode" =~ ^[0-7]{3,4}$ && "$stylesheet_mode" =~ ^[0-7]{3,4}$ ]] || return 0
        (( (8#$sprite_mode & 0022) == 0 && (8#$stylesheet_mode & 0022) == 0 )) || return 0
    fi

    digest="$(sha256sum -- "$sprite" 2>/dev/null | awk '{print $1}')"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        printf 'ORM installer: could not hash the cPanel icon sprite; leaving the cache key unchanged.\n' >&2
        return 0
    }
    current="$(grep -oE 'icon_spritemap\.svg\?[0-9a-f]+_[0-9]+(\.[0-9]+)*' "$stylesheet" | head -n 1 || true)"
    [[ -n "$current" ]] || {
        printf 'ORM installer: cPanel icon stylesheet has an unknown sprite URL; leaving it unchanged.\n' >&2
        return 0
    }
    [[ "$current" != "icon_spritemap.svg?${digest}_"* ]] || return 0

    temporary="$(mktemp "$(dirname -- "$stylesheet")/.icon-spritemap.css.XXXXXXXX")" || {
        printf 'ORM installer: could not prepare the cPanel icon stylesheet cache refresh.\n' >&2
        return 0
    }
    if ! ORM_ICON_SPRITE_CACHE_KEY="$digest" perl -0pe \
        's{(icon_spritemap\.svg\?)[0-9a-f]+(_[0-9]+(?:\.[0-9]+)*)}{$1$ENV{ORM_ICON_SPRITE_CACHE_KEY}$2}g' \
        -- "$stylesheet" >"$temporary" \
        || ! chmod --reference="$stylesheet" -- "$temporary" \
        || ! chown --reference="$stylesheet" -- "$temporary" \
        || ! mv -f -- "$temporary" "$stylesheet"; then
        rm -f -- "$temporary"
        printf 'ORM installer: failed to refresh the cPanel icon sprite cache key.\n' >&2
        return 0
    fi
}

orm_acquire_lifecycle_lock() {
    local script_path="${1:-}" status lock_mode
    shift || true
    command -v flock >/dev/null 2>&1 || orm_die 'flock is required to serialize ORM package operations.'
    [[ ! -L "$ORM_LIFECYCLE_LOCK" && ! -d "$ORM_LIFECYCLE_LOCK" ]] \
        || orm_die 'the ORM lifecycle lock path is unsafe.'
    install -d -o root -g root -m 0755 "$(dirname -- "$ORM_LIFECYCLE_LOCK")"
    if [[ "${ORM_LIFECYCLE_LOCK_HELD:-0}" == 1 ]]; then
        [[ -f "$ORM_LIFECYCLE_LOCK" && ! -L "$ORM_LIFECYCLE_LOCK" ]] \
            || orm_die 'the ORM lifecycle lock file is unsafe.'
        [[ "$(stat -c '%u' -- "$ORM_LIFECYCLE_LOCK")" == 0 ]] \
            || orm_die 'the ORM lifecycle lock file is not root-owned.'
        lock_mode="$(stat -c '%a' -- "$ORM_LIFECYCLE_LOCK")"
        (( (8#$lock_mode & 0022) == 0 )) || orm_die 'the ORM lifecycle lock file is writable by another user.'
        return 0
    fi
    [[ -n "$script_path" && -f "$script_path" ]] || orm_die 'could not identify the lifecycle script to lock.'
    umask 077
    ORM_LIFECYCLE_LOCK_HELD=1
    export ORM_LIFECYCLE_LOCK_HELD
    if flock -n -E 75 --close "$ORM_LIFECYCLE_LOCK" "$BASH" "$script_path" "$@"; then
        status=0
    else
        status=$?
    fi
    [[ "$status" -ne 75 ]] || orm_die 'another ORM install, upgrade, or uninstall is already running.'
    exit "$status"
}

orm_safe_target_parent_chain() {
    local target="${1:-}" parent rest component
    local -a components=()
    [[ "$target" == /* && "$target" != *//* ]] || return 1
    rest="${target#/}"
    IFS='/' read -r -a components <<<"$rest"
    for component in "${components[@]}"; do
        [[ "$component" != . && "$component" != .. ]] || return 1
    done
    parent="$(dirname -- "$target")"
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
        whm_audit_log "$ORM_REPO_ROOT/src/Orm/Security/WhmAuditLog.php" "$ORM_3RDPARTY/src/Orm/Security/WhmAuditLog.php" 644 \
        whm_audit_event_writer "$ORM_REPO_ROOT/src/Orm/Security/WhmAuditEventWriter.php" "$ORM_3RDPARTY/src/Orm/Security/WhmAuditEventWriter.php" 644 \
        whm_security_report "$ORM_REPO_ROOT/src/Orm/Security/WhmSecurityReport.php" "$ORM_3RDPARTY/src/Orm/Security/WhmSecurityReport.php" 644 \
        whm_security_report_policy "$ORM_REPO_ROOT/src/Orm/Security/WhmSecurityReportPolicyStore.php" "$ORM_3RDPARTY/src/Orm/Security/WhmSecurityReportPolicyStore.php" 644 \
        account_context "$ORM_REPO_ROOT/src/Orm/Cpanel/AuthenticatedAccountContext.php" "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php" 644 \
        broker_identity "$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerIdentityVerifier.php" "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php" 644 \
        broker_client "$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerClient.php" "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerClient.php" 644 \
        connection_details "$ORM_REPO_ROOT/src/Orm/Cpanel/ConnectionDetails.php" "$ORM_3RDPARTY/src/Orm/Cpanel/ConnectionDetails.php" 644 \
        diagnostic_report "$ORM_REPO_ROOT/src/Orm/Cpanel/DiagnosticReport.php" "$ORM_3RDPARTY/src/Orm/Cpanel/DiagnosticReport.php" 644 \
        health_guidance "$ORM_REPO_ROOT/src/Orm/Cpanel/HealthGuidance.php" "$ORM_3RDPARTY/src/Orm/Cpanel/HealthGuidance.php" 644 \
        podman_cache_discovery "$ORM_REPO_ROOT/src/Orm/Cpanel/PodmanCacheDiscovery.php" "$ORM_3RDPARTY/src/Orm/Cpanel/PodmanCacheDiscovery.php" 644 \
        podman_lifecycle_manager "$ORM_REPO_ROOT/src/Orm/Cpanel/PodmanLifecycleManager.php" "$ORM_3RDPARTY/src/Orm/Cpanel/PodmanLifecycleManager.php" 644 \
        application_discovery "$ORM_REPO_ROOT/src/Orm/Cpanel/ApplicationDiscovery.php" "$ORM_3RDPARTY/src/Orm/Cpanel/ApplicationDiscovery.php" 644 \
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
        broker_provider_event_config "$ORM_REPO_ROOT/src/Orm/Broker/ProviderEventConfig.pm" "$ORM_BROKER_LIB/ProviderEventConfig.pm" 644 \
        broker_provider_event_endpoint "$ORM_REPO_ROOT/src/Orm/Broker/ProviderEventEndpoint.pm" "$ORM_BROKER_LIB/ProviderEventEndpoint.pm" 644 \
        broker_provider_event_emitter "$ORM_REPO_ROOT/src/Orm/Broker/ProviderEventEmitter.pm" "$ORM_BROKER_LIB/ProviderEventEmitter.pm" 644 \
        broker_provider_event_queue "$ORM_REPO_ROOT/src/Orm/Broker/ProviderEventQueue.pm" "$ORM_BROKER_LIB/ProviderEventQueue.pm" 644 \
        broker_provider_event_transport "$ORM_REPO_ROOT/src/Orm/Broker/ProviderEventTransport.pm" "$ORM_BROKER_LIB/ProviderEventTransport.pm" 644 \
        broker_provider_events "$ORM_REPO_ROOT/src/Orm/Broker/ProviderEvents.pm" "$ORM_BROKER_LIB/ProviderEvents.pm" 644 \
        provider_events_worker "$ORM_REPO_ROOT/bin/orm-provider-events-worker.pl" "$ORM_3RDPARTY/bin/orm-provider-events-worker.pl" 755 \
        broker_unit "$ORM_PACKAGE_ROOT/systemd/orm-broker.service" "$ORM_BROKER_UNIT" 644 \
        provider_events_service "$ORM_PACKAGE_ROOT/systemd/orm-provider-events.service" "$ORM_PROVIDER_EVENTS_SERVICE" 644 \
        provider_events_timer "$ORM_PACKAGE_ROOT/systemd/orm-provider-events.timer" "$ORM_PROVIDER_EVENTS_TIMER" 644 \
        instance_unit "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" "$ORM_INSTANCE_UNIT" 644 \
        metrics_service "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.service" "$ORM_METRICS_SERVICE" 644 \
        metrics_timer "$ORM_PACKAGE_ROOT/systemd/orm-metrics-collect@.timer" "$ORM_METRICS_TIMER" 644 \
        provider_policy_store "$ORM_REPO_ROOT/src/Orm/Backend/ProviderPolicyStore.php" "$ORM_3RDPARTY/src/Orm/Backend/ProviderPolicyStore.php" 644 \
        broker_provider_policy "$ORM_REPO_ROOT/src/Orm/Broker/ProviderPolicy.pm" "$ORM_BROKER_LIB/ProviderPolicy.pm" 644 \
        release_version "$ORM_REPO_ROOT/VERSION" "$ORM_3RDPARTY/VERSION" 644 \
        release_preview "$ORM_PACKAGE_ROOT/preview-release.sh" "$ORM_3RDPARTY/packaging/preview-release.sh" 755 \
        release_apply "$ORM_PACKAGE_ROOT/apply-release.sh" "$ORM_3RDPARTY/packaging/apply-release.sh" 755 \
        release_recover "$ORM_PACKAGE_ROOT/recover-release.sh" "$ORM_3RDPARTY/packaging/recover-release.sh" 755 \
        release_worker "$ORM_REPO_ROOT/bin/orm-update-worker.pl" "$ORM_3RDPARTY/bin/orm-update-worker.pl" 755 \
        release_package_lib "$ORM_PACKAGE_ROOT/lib.sh" "$ORM_3RDPARTY/packaging/lib.sh" 644 \
        release_verification_lib "$ORM_PACKAGE_ROOT/release-lib.sh" "$ORM_3RDPARTY/packaging/release-lib.sh" 644 \
        release_archive_inspector "$ORM_PACKAGE_ROOT/inspect-release-archive.pl" "$ORM_3RDPARTY/packaging/inspect-release-archive.pl" 644 \
        release_preview_comparator "$ORM_PACKAGE_ROOT/compare-release-preview.pl" "$ORM_3RDPARTY/packaging/compare-release-preview.pl" 644 \
        release_install_map "$ORM_PACKAGE_ROOT/release-install-map.txt" "$ORM_3RDPARTY/packaging/release-install-map.txt" 644 \
        release_required_files "$ORM_PACKAGE_ROOT/release-required-files.txt" "$ORM_3RDPARTY/packaging/release-required-files.txt" 644 \
        release_preview_ui "$ORM_REPO_ROOT/src/Orm/Update/ReleasePreview.php" "$ORM_3RDPARTY/src/Orm/Update/ReleasePreview.php" 644 \
        release_apply_ui "$ORM_REPO_ROOT/src/Orm/Update/ReleaseApplyJob.php" "$ORM_3RDPARTY/src/Orm/Update/ReleaseApplyJob.php" 644 \
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

orm_appconfig_matches_package() {
    local target="${1:-$ORM_APPCONFIG}" source="$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf"
    local manifest_owner manifest_mode expected_digest actual_digest
    [[ -f "$target" && ! -L "$target" ]] || return 1
    # register_appconfig adds the registered application name after the packaged settings.
    if [[ -f "$source" && ! -L "$source" ]]; then
        if cmp -s -- "$target" <(cat -- "$source"; printf '\nname=open_redis_manager\n'); then
            return 0
        fi
        return 1
    fi

    # Older installs do not carry the package template beside the installed updater.
    # In that case, accept only the exact root-owned AppConfig digest in the install manifest.
    [[ -f "$ORM_INSTALL_MANIFEST" && ! -L "$ORM_INSTALL_MANIFEST" ]] || return 1
    manifest_owner="$(stat -c '%u' -- "$ORM_INSTALL_MANIFEST")" || return 1
    manifest_mode="$(stat -c '%a' -- "$ORM_INSTALL_MANIFEST")" || return 1
    [[ "$manifest_owner" == 0 && "$manifest_mode" == 600 ]] || return 1
    expected_digest="$(awk -F'|' '$1 == "whm_appconfig" { if (found++) exit 2; print $3 } END { if (!found) exit 1 }' \
        "$ORM_INSTALL_MANIFEST")" || return 1
    [[ "$expected_digest" =~ ^[a-f0-9]{64}$ ]] || return 1
    actual_digest="$(sha256sum -- "$target" | awk '{print $1}')" || return 1
    [[ "$actual_digest" == "$expected_digest" ]]
}

orm_validate_legacy_identity_v1() {
    local manifest="$ORM_PACKAGE_ROOT/legacy/identity-v1/install.manifest"
    local key target mode expected_mode expected_digest actual_digest file_owner
    local -A recorded=() expected=()
    [[ -f "$manifest" && ! -L "$manifest" ]] \
        || { printf 'ORM upgrader: legacy baseline manifest is missing or unsafe.\n' >&2; return 1; }
    [[ "$(head -n 1 -- "$manifest")" == orm-identity-install-v1 ]] \
        || { printf 'ORM upgrader: legacy baseline manifest version is unsupported.\n' >&2; return 1; }
    while IFS='|' read -r key mode expected_digest; do
        [[ "$key" =~ ^[a-z_]+$ && "$mode" =~ ^[0-7]{3,4}$ && "$expected_digest" =~ ^[a-f0-9]{64}$ ]] \
            || { printf 'ORM upgrader: legacy baseline manifest contains an invalid record.\n' >&2; return 1; }
        [[ -z "${recorded[$key]+present}" ]] \
            || { printf 'ORM upgrader: legacy baseline manifest repeats a file key.\n' >&2; return 1; }
        recorded[$key]="$mode|$expected_digest"
    done < <(tail -n +2 -- "$manifest")
    while IFS='|' read -r key target mode; do
        expected[$key]=1
        orm_safe_target_parent_chain "$target" \
            || { printf 'ORM upgrader: legacy target directory is unsafe for %s.\n' "$key" >&2; return 1; }
        [[ -n "${recorded[$key]+present}" && -f "$target" && ! -L "$target" ]] \
            || { printf 'ORM upgrader: a legacy install file is missing or unsafe (%s).\n' "$key" >&2; return 1; }
        file_owner="$(stat -c '%u' -- "$target")" \
            || { printf 'ORM upgrader: could not read ownership for %s.\n' "$key" >&2; return 1; }
        [[ "$file_owner" == 0 ]] \
            || { printf 'ORM upgrader: legacy install file is not root-owned (%s).\n' "$key" >&2; return 1; }
        IFS='|' read -r expected_mode expected_digest <<<"${recorded[$key]}"
        [[ "$expected_mode" == "$mode" && "$(stat -c '%a' -- "$target")" == "$mode" ]] \
            || { printf 'ORM upgrader: legacy install file has an unexpected mode (%s).\n' "$key" >&2; return 1; }
        actual_digest="$(sha256sum -- "$target" | awk '{print $1}')" \
            || { printf 'ORM upgrader: could not verify the content of %s.\n' "$key" >&2; return 1; }
        [[ "$actual_digest" == "$expected_digest" ]] \
            || { printf 'ORM upgrader: legacy install file content does not match the baseline (%s).\n' "$key" >&2; return 1; }
    done < <(orm_legacy_identity_v1_file_map)
    [[ "${#recorded[@]}" -eq "${#expected[@]}" ]] \
        || { printf 'ORM upgrader: legacy baseline manifest file count does not match the supported package.\n' >&2; return 1; }
}

orm_legacy_managed_v1_file_map() {
    local map="$ORM_PACKAGE_ROOT/legacy/managed-v1/files.map"
    local key source_kind source_rel target_kind target_rel mode digest extra source_root target_root source target current_line
    local current_key current_source current_target current_mode count=0
    local -A seen=()
    [[ -f "$map" && ! -L "$map" ]] || return 1
    while IFS='|' read -r key source_kind source_rel target_kind target_rel mode digest extra; do
        [[ "$key" =~ ^[a-z_]+$ && -z "${seen[$key]+present}" \
            && ( "$source_kind" == package || "$source_kind" == repo ) \
            && "$source_rel" != /* && "$source_rel" != *'|'* \
            && "$target_rel" != /* && "$target_rel" != *'|'* \
            && "$mode" =~ ^[0-7]{3,4}$ && "$digest" =~ ^[a-f0-9]{64}$ \
            && -z "${extra:-}" ]] || return 1
        case "/$source_rel/" in *"/../"*|*"/./"*) return 1 ;; esac
        case "/$target_rel/" in *"/../"*|*"/./"*) return 1 ;; esac
        case "$source_kind" in
            package) source_root="$ORM_PACKAGE_ROOT" ;;
            repo) source_root="$ORM_REPO_ROOT" ;;
        esac
        case "$target_kind" in
            cpanel-live) target_root="$ORM_CPanel_LIVE" ;;
            whm-cgi) target_root="$ORM_WHM_CGI" ;;
            whm-icons) target_root="$ORM_WHM_ICONS" ;;
            thirdparty) target_root="$ORM_3RDPARTY" ;;
            systemd) target_root="$(dirname -- "$ORM_BROKER_UNIT")" ;;
            appconfig) target_root="$(dirname -- "$ORM_APPCONFIG")" ;;
            *) return 1 ;;
        esac
        source="$source_root/$source_rel"
        target="$target_root/$target_rel"
        current_line="$(orm_package_file_map | awk -F'|' -v wanted="$key" '$1 == wanted { print; count++ } END { if (count != 1) exit 1 }')" || return 1
        IFS='|' read -r current_key current_source current_target current_mode <<<"$current_line"
        [[ "$current_key" == "$key" && "$current_source" == "$source" \
            && "$current_target" == "$target" && "$current_mode" == "$mode" ]] || return 1
        seen[$key]=1
        ((count += 1))
        printf '%s|%s|%s|%s|%s\n' "$key" "$source" "$target" "$mode" "$digest"
    done <"$map"
    [[ "$count" -eq 28 ]]
}

orm_release_install_map_is_compatible() {
    local candidate="$1" installed="$2" approved_addition
    approved_addition='application_discovery|src/Orm/Cpanel/ApplicationDiscovery.php|/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/ApplicationDiscovery.php|644'
    [[ -f "$candidate" && ! -L "$candidate" && -f "$installed" && ! -L "$installed" ]] || return 1
    cmp -s -- "$candidate" "$installed" && return 0
    [[ "$(grep -Fxc -- "$approved_addition" "$candidate")" == 1 ]] || return 1
    cmp -s -- <(grep -Fvx -- "$approved_addition" "$candidate") "$installed"
}

orm_legacy_managed_v1_expected_manifest() {
    local key source target mode digest
    printf 'orm-install-manifest-v1\n'
    while IFS='|' read -r key source target mode digest; do
        printf '%s|%s|%s\n' "$key" "$mode" "$digest"
    done < <(orm_legacy_managed_v1_file_map)
}

orm_safe_root_owned_parent_chain() {
    local parent owner mode mode_bits
    parent="$(dirname -- "$1")"
    while [[ "$parent" != / ]]; do
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
        owner="$(stat -c '%u' -- "$parent")" || return 1
        mode="$(stat -c '%a' -- "$parent")" || return 1
        [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_bits=$((8#$mode))
        if (( (mode_bits & 0022) != 0 && (mode_bits & 01000) == 0 )); then return 1; fi
        parent="$(dirname -- "$parent")"
    done
}

orm_validate_legacy_managed_v1_instance_roots() {
    local path owner mode
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        orm_safe_root_owned_parent_chain "$path" || return 1
        [[ ! -L "$path" ]] || return 1
        [[ ! -e "$path" ]] && continue
        [[ -d "$path" ]] || return 1
        owner="$(stat -c '%u' -- "$path")" || return 1
        mode="$(stat -c '%a' -- "$path")" || return 1
        [[ "$owner" == 0 && "$mode" == 711 ]] || return 1
    done
}

orm_record_upgrade_created_managed_directories() {
    local baseline="$1" recorded="$2" path identity
    [[ -f "$baseline" && ! -L "$baseline" && -f "$recorded" && ! -L "$recorded" ]] || return 1
    while IFS= read -r path; do
        [[ "$path" == "$ORM_3RDPARTY/"* ]] || return 1
        grep -Fxq -- "$path" "$baseline" && continue
        grep -Fq -- "$path|" "$recorded" && continue
        identity="$(stat -c '%d:%i:%u:%g:%a' -- "$path")" || return 1
        printf '%s|%s\n' "$path" "$identity" >>"$recorded" || return 1
    done < <(find "$ORM_3RDPARTY" -mindepth 1 -type d -print)
}

orm_remove_upgrade_created_managed_directories() {
    local recorded="$1" path identity actual
    [[ -f "$recorded" && ! -L "$recorded" ]] || return 1
    while IFS='|' read -r path identity; do
        [[ "$path" == "$ORM_3RDPARTY/"* \
            && "$identity" =~ ^[0-9]+:[0-9]+:0:0:[0-7]{3,4}$ ]] || return 1
        [[ ! -e "$path" && ! -L "$path" ]] && continue
        [[ -d "$path" && ! -L "$path" ]] || return 1
        actual="$(stat -c '%d:%i:%u:%g:%a' -- "$path")" || return 1
        [[ "$actual" == "$identity" ]] || return 1
        rmdir -- "$path" || return 1
    done < <(LC_ALL=C sort -t'|' -k1,1r -- "$recorded")
}

orm_prepare_upgrade_instance_directories() {
    local path identity
    ORM_CREATED_INSTANCE_ROOTS=()
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        if [[ -e "$path" ]]; then
            [[ -d "$path" && ! -L "$path" \
                && "$(stat -c '%u:%a' -- "$path")" == 0:711 ]] \
                || orm_die 'an existing instance data root changed after preflight.'
            continue
        fi
        [[ ! -L "$path" ]] || orm_die 'an unsafe instance data root appeared after preflight.'
        mkdir -m 0711 -- "$path" || orm_die 'could not create an ORM runtime directory.'
        identity="$(stat -c '%d:%i:%u:%a' -- "$path")" || orm_die 'could not verify a new ORM runtime directory.'
        ORM_CREATED_INSTANCE_ROOTS+=("$path|$identity")
        chown root:root -- "$path" || orm_die 'could not secure an ORM runtime directory.'
        chmod 0711 -- "$path" || orm_die 'could not set private traversal permissions on an ORM runtime directory.'
    done
}

orm_validate_legacy_managed_v1() {
    local manifest="$ORM_INSTALL_MANIFEST" baseline="$ORM_PACKAGE_ROOT/legacy/managed-v1/install.manifest"
    local key source target mode expected_digest actual_digest owner manifest_mode count=0
    local expected_inventory actual_inventory expected_cpanel_file actual_cpanel_files
    local -A targets=()
    [[ -f "$baseline" && ! -L "$baseline" ]] || return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    owner="$(stat -c '%u' -- "$manifest")" || return 1
    manifest_mode="$(stat -c '%a' -- "$manifest")" || return 1
    [[ "$owner" == 0 && "$manifest_mode" == 600 ]] || return 1
    cmp -s -- "$baseline" "$manifest" \
        && cmp -s -- "$baseline" <(orm_legacy_managed_v1_expected_manifest) || return 1

    while IFS='|' read -r key source target mode expected_digest; do
        [[ -n "$key" && -z "${targets[$target]+present}" ]] || return 1
        orm_safe_root_owned_parent_chain "$target" || return 1
        [[ -f "$target" && ! -L "$target" ]] || return 1
        [[ "$(stat -c '%u' -- "$target")" == 0 \
            && "$(stat -c '%a' -- "$target")" == "$mode" ]] || return 1
        actual_digest="$(sha256sum -- "$target" | awk '{print $1}')" || return 1
        [[ "$actual_digest" == "$expected_digest" ]] || return 1
        targets[$target]=1
        ((count += 1))
    done < <(orm_legacy_managed_v1_file_map)
    [[ "$count" -eq 28 ]] || return 1

    expected_inventory="$(
        printf '%s\n' "$manifest"
        while IFS='|' read -r key source target mode expected_digest; do
            [[ "$target" == "$ORM_3RDPARTY/"* ]] || continue
            printf '%s\n' "$target"
            parent="$(dirname -- "$target")"
            while [[ "$parent" == "$ORM_3RDPARTY/"* ]]; do
                printf '%s\n' "$parent"
                parent="$(dirname -- "$parent")"
            done
        done < <(orm_legacy_managed_v1_file_map)
    )"
    actual_inventory="$(find "$ORM_3RDPARTY" -mindepth 1 -print | LC_ALL=C sort)" || return 1
    expected_inventory="$(printf '%s\n' "$expected_inventory" | LC_ALL=C sort -u)"
    [[ "$actual_inventory" == "$expected_inventory" ]] || return 1

    expected_cpanel_file="$ORM_CPanel_LIVE/index.live.php"
    [[ -d "$ORM_CPanel_LIVE" && ! -L "$ORM_CPanel_LIVE" ]] || return 1
    actual_cpanel_files="$(find "$ORM_CPanel_LIVE" -mindepth 1 -print | LC_ALL=C sort)" || return 1
    [[ "$actual_cpanel_files" == "$expected_cpanel_file" ]] || return 1
    orm_validate_legacy_managed_v1_instance_roots || return 1
}

orm_write_install_manifest() {
    local destination="$1" key source target mode digest owner temporary version
    version="$(orm_read_package_version)" || orm_die 'the package version file is missing or invalid.'
    temporary="${destination}.tmp.$$"
    (umask 077; printf 'orm-install-manifest-v3\nversion|%s\n' "$version" >"$temporary") \
        || orm_die 'could not create the ORM install manifest.'
    while IFS='|' read -r key source target mode; do
        [[ -f "$target" && ! -L "$target" ]] || orm_die "cannot manifest an unsafe installed file: $target"
        owner="$(stat -c '%u' -- "$target")" || orm_die "could not verify installed file owner: $target"
        [[ "$owner" == 0 ]] || orm_die "installed file is not root-owned: $target"
        [[ "$(stat -c '%a' -- "$target")" == "$mode" ]] || orm_die "installed file mode does not match the package: $target"
        digest="$(sha256sum -- "$target" | awk '{print $1}')" || orm_die "could not hash installed file: $target"
        printf '%s|%s|%s|%s\n' "$key" "$mode" "$digest" "$target" >>"$temporary"
    done < <(orm_package_file_map)
    chmod 0600 -- "$temporary"
    chown root:root -- "$temporary"
    mv -f -- "$temporary" "$destination"
}

orm_adopt_current_install_manifest() {
    local manifest="$1" header installed_version package_version temporary
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    header="$(head -n 1 -- "$manifest")" || return 1
    case "$header" in
        orm-install-manifest-v1) ;;
        orm-install-manifest-v2)
            installed_version="$(orm_install_manifest_version "$manifest")" || return 1
            package_version="$(orm_read_package_version)" || return 1
            [[ "$installed_version" == "$package_version" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    orm_validate_install_manifest "$manifest" || return 1
    orm_installed_files_match_current_package || return 1
    temporary="$(mktemp "$(dirname -- "$manifest")/.orm-adopt-manifest.XXXXXXXX")" || return 1
    if ! (orm_write_install_manifest "$temporary") || ! orm_validate_install_manifest "$temporary"; then
        rm -f -- "$temporary" "$temporary.tmp.$$"
        return 1
    fi
    if ! mv -f -- "$temporary" "$manifest"; then
        rm -f -- "$temporary"
        return 1
    fi
}

orm_installed_files_match_current_package() {
    local key source target mode source_owner installed_mode owner
    while IFS='|' read -r key source target mode; do
        [[ -f "$source" && ! -L "$source" && -f "$target" && ! -L "$target" ]] || return 1
        source_owner="$(stat -c '%u' -- "$source")" || return 1
        owner="$(stat -c '%u' -- "$target")" || return 1
        installed_mode="$(stat -c '%a' -- "$target")" || return 1
        [[ "$source_owner" == 0 && "$owner" == 0 && "$installed_mode" == "$mode" ]] || return 1
        if [[ "$key" == whm_appconfig ]]; then
            orm_appconfig_matches_package "$target" || return 1
            continue
        fi
        cmp -s -- "$source" "$target" || return 1
    done < <(orm_package_file_map)
}

orm_installation_matches_current_package() {
    [[ -f "$ORM_INSTALL_MANIFEST" && ! -L "$ORM_INSTALL_MANIFEST" ]] || return 1
    orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" || return 1
    orm_installed_files_match_current_package || return 1
    orm_registration_state || return 1
    local path owner mode
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        [[ -d "$path" && ! -L "$path" ]] || return 1
        owner="$(stat -c '%u' -- "$path")" || return 1
        mode="$(stat -c '%a' -- "$path")" || return 1
        [[ "$owner" == 0 && "$mode" == 711 ]] || return 1
    done
}

orm_installation_is_absent() {
    local key source target mode status
    while IFS='|' read -r key source target mode; do
        [[ ! -e "$target" && ! -L "$target" ]] || return 1
    done < <(orm_package_file_map)
    [[ ! -e "$ORM_INSTALL_MANIFEST" && ! -L "$ORM_INSTALL_MANIFEST" \
        && ! -e "$ORM_APPCONFIG" && ! -L "$ORM_APPCONFIG" ]] || return 1
    if orm_registration_state; then
        return 1
    else
        status=$?
        [[ "$status" -eq 1 ]] || return 1
    fi
}

orm_validate_install_manifest() {
    local manifest="$1" validation_mode="${2:-strict}" key source target mode expected_digest actual_digest owner manifest_mode file_owner file_mode header version records_start recorded_target extra expected_target expected_mode release_version_path=''
    local -a installed_version_lines=()
    local -A recorded=() expected=() expected_targets=()
    [[ "$validation_mode" == strict || "$validation_mode" == allow-known-subset ]] || return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    owner="$(stat -c '%u' -- "$manifest")" || return 1
    manifest_mode="$(stat -c '%a' -- "$manifest")" || return 1
    [[ "$owner" == 0 && "$manifest_mode" == 600 ]] || return 1
    header="$(head -n 1 -- "$manifest")"
    case "$header" in
        orm-install-manifest-v1) records_start=2 ;;
        orm-install-manifest-v2|orm-install-manifest-v3)
            IFS='|' read -r key version < <(sed -n '2p' -- "$manifest")
            [[ "$key" == version ]] && orm_valid_version "$version" || return 1
            records_start=3
            ;;
        *) return 1 ;;
    esac
    [[ "$validation_mode" != allow-known-subset || "$header" == orm-install-manifest-v3 ]] || return 1
    while IFS='|' read -r key mode expected_digest recorded_target extra; do
        [[ "$key" =~ ^[a-z_]+$ && "$mode" =~ ^[0-7]{3,4}$ && "$expected_digest" =~ ^[a-f0-9]{64}$ && -z "${extra:-}" ]] || return 1
        if [[ "$header" == orm-install-manifest-v3 ]]; then
            [[ "$recorded_target" == /* && "$recorded_target" != *'|'* ]] || return 1
        else
            [[ -z "${recorded_target:-}" ]] || return 1
        fi
        [[ -z "${recorded[$key]+present}" ]] || return 1
        recorded[$key]="$mode|$expected_digest|${recorded_target:-}"
    done < <(tail -n +"$records_start" -- "$manifest")
    [[ "${#recorded[@]}" -gt 0 ]] || return 1
    while IFS='|' read -r key source target mode; do
        [[ -z "${expected[$key]+present}" && -z "${expected_targets[$target]+present}" ]] || return 1
        expected[$key]="$target|$mode"
        expected_targets[$target]=1
        [[ "$key" != release_version ]] || release_version_path="$target"
        orm_safe_target_parent_chain "$target" || return 1
    done < <(orm_package_file_map)
    for key in "${!recorded[@]}"; do
        [[ -n "${expected[$key]+present}" ]] || return 1
        IFS='|' read -r expected_target expected_mode <<<"${expected[$key]}"
        IFS='|' read -r file_mode expected_digest recorded_target <<<"${recorded[$key]}"
        if [[ "$header" == orm-install-manifest-v3 ]]; then
            [[ "$recorded_target" == "$expected_target" ]] || return 1
        fi
        [[ "$file_mode" == "$expected_mode" && -f "$expected_target" && ! -L "$expected_target" ]] || return 1
        file_owner="$(stat -c '%u' -- "$expected_target")" || return 1
        [[ "$file_owner" == 0 ]] || return 1
        [[ "$(stat -c '%a' -- "$expected_target")" == "$expected_mode" ]] || return 1
        actual_digest="$(sha256sum -- "$expected_target" | awk '{print $1}')" || return 1
        [[ "$actual_digest" == "$expected_digest" ]] || return 1
    done
    if [[ "$header" != orm-install-manifest-v1 && -n "$release_version_path" ]]; then
        [[ -f "$release_version_path" && ! -L "$release_version_path" ]] || return 1
        mapfile -t installed_version_lines <"$release_version_path" || return 1
        [[ "${#installed_version_lines[@]}" -eq 1 && "${installed_version_lines[0]}" == "$version" ]] || return 1
    fi
    if [[ "$validation_mode" == strict ]]; then
        [[ "${#recorded[@]}" -eq "${#expected[@]}" ]]
    else
        [[ "${#recorded[@]}" -le "${#expected[@]}" ]]
    fi
}

orm_valid_version() {
    local version="${1:-}"
    "$ORM_PERL" -e '
        my $version = shift // q{};
        my $number = qr/(?:0|[1-9][0-9]*)/;
        my $prerelease = qr/(?:$number|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)/;
        exit($version =~ /\A$number\.$number\.$number(?:-$prerelease(?:\.$prerelease)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/ ? 0 : 1);
    ' "$version"
}

orm_read_package_version() {
    local version
    [[ -f "$ORM_VERSION_FILE" && ! -L "$ORM_VERSION_FILE" ]] || return 1
    IFS= read -r version <"$ORM_VERSION_FILE" || return 1
    orm_valid_version "$version" || return 1
    [[ "$(wc -l <"$ORM_VERSION_FILE" | tr -d '[:space:]')" == 1 ]] || return 1
    printf '%s\n' "$version"
}

orm_install_manifest_version() {
    local manifest="$1" header key version
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    header="$(head -n 1 -- "$manifest")"
    case "$header" in
        orm-install-manifest-v1) return 0 ;;
        orm-install-manifest-v2|orm-install-manifest-v3)
            IFS='|' read -r key version < <(sed -n '2p' -- "$manifest")
            [[ "$key" == version ]] && orm_valid_version "$version" || return 1
            printf '%s\n' "$version"
            ;;
        *) return 1 ;;
    esac
}

orm_require_root_and_platform() {
    [[ "$(id -u)" -eq 0 ]] || orm_die 'run this script as root.'
    [[ "$(uname -s)" == Linux ]] || orm_die 'cPanel & WHM installation is supported only on Linux.'
    [[ -x "$ORM_INSTALL_PLUGIN" && -x "$ORM_UNINSTALL_PLUGIN" ]] || orm_die 'cPanel plugin lifecycle scripts were not found.'
    [[ -x "$ORM_REGISTER_APPCONFIG" && -x "$ORM_UNREGISTER_APPCONFIG" && -x "$ORM_IS_REGISTERED" ]] || orm_die 'WHM AppConfig lifecycle scripts were not found.'
    [[ -x "$ORM_PERL" && -x "$ORM_SYSTEMCTL" ]] || orm_die 'Perl or systemd is required for the ORM identity broker.'
    [[ -f "$ORM_CPANEL_ROOT/php/WHM.php" && -f "$ORM_CPANEL_ROOT/php/cpanel.php" ]] || orm_die 'expected cPanel PHP interface files were not found.'
}

orm_require_provider_event_tls() {
    "$ORM_PERL" -MIO::Socket::SSL -e 1 >/dev/null 2>&1 \
        || orm_die 'the provider event worker requires the IO::Socket::SSL Perl module.'
}

orm_make_cpanel_archive() {
    local destination="$1"
    local stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/orm-cpanel.XXXXXXXX")"
    if ! mkdir -p "$stage/orm" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/install.json" "$stage/orm/install.json" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-cpanel-group-v4.svg" "$stage/orm/orm-cpanel-group-v4.svg" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-cpanel-group-v4.png" "$stage/orm/orm-cpanel-group-v4.png" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-cpanel-feature-v4.svg" "$stage/orm/orm-cpanel-feature-v4.svg" \
        || ! install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-cpanel-feature-v4.png" "$stage/orm/orm-cpanel-feature-v4.png" \
        || ! tar -czf "$destination" -C "$stage/orm" install.json orm-cpanel-group-v4.svg orm-cpanel-group-v4.png orm-cpanel-feature-v4.svg orm-cpanel-feature-v4.png; then
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

orm_make_legacy_managed_v1_cpanel_archive() {
    local destination="$1" legacy="$ORM_PACKAGE_ROOT/legacy/managed-v1/cpanel" stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/orm-cpanel-managed-legacy.XXXXXXXX")"
    if ! mkdir -p "$stage/orm" \
        || ! install -m 0644 "$legacy/install.json" "$stage/orm/install.json" \
        || ! install -m 0644 "$legacy/orm-group.svg" "$stage/orm/orm-group.svg" \
        || ! install -m 0644 "$legacy/orm-feature.svg" "$stage/orm/orm-feature.svg" \
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
    local path unit_state source target mode key registration_status
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
        registration_status=$?
        [[ "$registration_status" -eq 1 ]] || orm_die 'could not safely verify WHM AppConfig registration.'
    fi
}

orm_prepare_instance_directories() {
    local path identity
    ORM_CREATED_INSTANCE_ROOTS=()
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        [[ ! -e "$path" && ! -L "$path" ]] || orm_die "refusing to replace an existing ORM runtime path: $path"
        mkdir -m 0711 -- "$path" || orm_die "could not create the ORM runtime directory: $path"
        identity="$(stat -c '%d:%i:%u:%a' -- "$path")" || orm_die "could not verify the new ORM runtime directory: $path"
        ORM_CREATED_INSTANCE_ROOTS+=("$path|$identity")
        chown root:root -- "$path" || orm_die "could not secure the ORM runtime directory: $path"
        chmod 0711 -- "$path" || orm_die "could not set private traversal permissions on: $path"
    done
}

orm_prepare_provider_event_storage() {
    local path owner mode identity
    ORM_CREATED_PROVIDER_EVENT_PATHS=()
    for path in "$ORM_PROVIDER_EVENTS_ROOT" "$ORM_PROVIDER_EVENTS_OUTBOX"; do
        if [[ ! -e "$path" && ! -L "$path" ]]; then
            mkdir -m 0700 -- "$path" || orm_die "could not create the provider event directory: $path"
            identity="$(stat -c '%d:%i' -- "$path")" || orm_die "could not identify the provider event directory: $path"
            ORM_CREATED_PROVIDER_EVENT_PATHS+=("$path|$identity|directory")
            chown root:root -- "$path" || orm_die "could not secure the provider event directory: $path"
            chmod 0700 -- "$path" || orm_die "could not set provider event directory permissions: $path"
        fi
        [[ -d "$path" && ! -L "$path" ]] || orm_die "provider event storage path is unsafe: $path"
        owner="$(stat -c '%u' -- "$path")" || orm_die "could not inspect provider event storage: $path"
        mode="$(stat -c '%a' -- "$path")" || orm_die "could not inspect provider event storage mode: $path"
        [[ "$owner" == 0 && "$mode" == 700 ]] || orm_die "provider event storage must be root-owned mode 0700: $path"
    done
    if [[ ! -e "$ORM_PROVIDER_EVENTS_CONFIG" && ! -L "$ORM_PROVIDER_EVENTS_CONFIG" ]]; then
        local temporary
        temporary="$(mktemp /etc/.orm-provider-events.XXXXXXXX)" \
            || orm_die 'could not create the default provider event configuration.'
        identity="$(stat -c '%d:%i' -- "$temporary")" || orm_die 'could not identify the temporary provider event configuration.'
        ORM_CREATED_PROVIDER_EVENT_PATHS+=("$temporary|$identity|temporary")
        chmod 0600 -- "$temporary" || orm_die 'could not secure the provider event configuration.'
        printf '{"destination":"","enabled":false,"signing_key":"","version":1}\n' >"$temporary" \
            || orm_die 'could not write the default provider event configuration.'
        chown root:root -- "$temporary" || orm_die 'could not secure the provider event configuration owner.'
        ln -- "$temporary" "$ORM_PROVIDER_EVENTS_CONFIG" || orm_die 'could not install the default provider event configuration.'
        identity="$(stat -c '%d:%i' -- "$ORM_PROVIDER_EVENTS_CONFIG")" || orm_die 'could not identify the default provider event configuration.'
        ORM_CREATED_PROVIDER_EVENT_PATHS+=("$ORM_PROVIDER_EVENTS_CONFIG|$identity|config")
        rm -f -- "$temporary"
    fi
    [[ -f "$ORM_PROVIDER_EVENTS_CONFIG" && ! -L "$ORM_PROVIDER_EVENTS_CONFIG" \
        && "$(stat -c '%u:%a' -- "$ORM_PROVIDER_EVENTS_CONFIG" 2>/dev/null)" == 0:600 ]] \
        || orm_die 'provider event configuration exists with unsafe ownership or permissions.'
}

orm_remove_prepared_provider_event_storage() {
    local entry path identity kind current_identity
    for (( index=${#ORM_CREATED_PROVIDER_EVENT_PATHS[@]}-1; index>=0; index-- )); do
        entry="${ORM_CREATED_PROVIDER_EVENT_PATHS[$index]}"
        IFS='|' read -r path identity kind <<< "$entry"
        [[ ! -e "$path" && ! -L "$path" ]] && continue
        current_identity="$(stat -c '%d:%i' -- "$path" 2>/dev/null)" || return 1
        [[ "$current_identity" == "$identity" ]] || return 1
        if [[ "$kind" == config ]]; then
            [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%a' -- "$path")" == 0:600 ]] || return 1
            cmp -s -- "$path" <(printf '{"destination":"","enabled":false,"signing_key":"","version":1}\n') || return 1
            rm -f -- "$path" || return 1
        elif [[ "$kind" == temporary ]]; then
            [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%a' -- "$path")" == 0:600 ]] || return 1
            rm -f -- "$path" || return 1
        else
            [[ -d "$path" && ! -L "$path" && "$(stat -c '%u:%a' -- "$path")" == 0:700 ]] || return 1
            rmdir -- "$path" || return 1
        fi
    done
    ORM_CREATED_PROVIDER_EVENT_PATHS=()
}

orm_remove_prepared_instance_directories() {
    local entry path identity current_identity
    for entry in "${ORM_CREATED_INSTANCE_ROOTS[@]}"; do
        IFS='|' read -r path identity <<< "$entry"
        [[ ! -e "$path" && ! -L "$path" ]] && continue
        [[ -d "$path" && ! -L "$path" ]] || return 1
        current_identity="$(stat -c '%d:%i:%u:%a' -- "$path" 2>/dev/null)" || return 1
        [[ "$current_identity" == "$identity" ]] || return 1
        rmdir -- "$path" || return 1
    done
    ORM_CREATED_INSTANCE_ROOTS=()
}

orm_remove_empty_owned_directories() {
    local path
    for path in \
        "$ORM_3RDPARTY/src/Orm/Backend" \
        "$ORM_3RDPARTY/src/Orm/Security" \
        "$ORM_3RDPARTY/src/Orm/Cpanel" \
        "$ORM_BROKER_LIB" \
        "$ORM_3RDPARTY/lib/Orm" \
        "$ORM_3RDPARTY/lib" \
        "$ORM_3RDPARTY/bin" \
        "$ORM_3RDPARTY/src/Orm/Update" \
        "$ORM_3RDPARTY/src/Orm" \
        "$ORM_3RDPARTY/src" \
        "$ORM_3RDPARTY/packaging" \
        "$ORM_3RDPARTY" \
        "$ORM_CPanel_LIVE"; do
        rmdir -- "$path" 2>/dev/null || true
    done
}

orm_remove_empty_instance_directories() {
    local path owner mode entries
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        [[ -d "$path" && ! -L "$path" ]] || return 1
        owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
        mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
        [[ "$owner" == 0 && "$mode" == 711 ]] || return 1
        entries="$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" || return 1
        [[ -z "$entries" ]] || return 1
        rmdir -- "$path" || return 1
    done
}

orm_restore_empty_instance_directories() {
    local path
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        if [[ ! -e "$path" && ! -L "$path" ]]; then
            mkdir -m 0711 -- "$path" || return 1
            chown root:root -- "$path" || return 1
            chmod 0711 -- "$path" || return 1
            continue
        fi
        [[ -d "$path" && ! -L "$path" \
            && "$(stat -c '%u:%a' -- "$path" 2>/dev/null)" == 0:711 ]] || return 1
        [[ -z "$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" ]] || return 1
    done
}

orm_verify_installed_files() {
    local source target mode key
    while IFS='|' read -r key source target mode; do
        [[ ! -e "$target" && ! -L "$target" ]] && continue
        if [[ "$key" == whm_appconfig ]]; then
            orm_appconfig_matches_package "$target" || orm_die 'the registered WHM AppConfig file differs from this package; refusing removal.'
            continue
        fi
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

orm_wait_for_broker_socket() {
    local attempt active socket_identity runtime_identity
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
        case "$active" in
            failed|inactive) return 1 ;;
        esac
        if [[ -e "$ORM_BROKER_SOCKET" || -L "$ORM_BROKER_SOCKET" ]]; then
            [[ -S "$ORM_BROKER_SOCKET" && ! -L "$ORM_BROKER_SOCKET" ]] || return 1
            [[ -d "$(dirname -- "$ORM_BROKER_SOCKET")" && ! -L "$(dirname -- "$ORM_BROKER_SOCKET")" ]] || return 1
            socket_identity="$(stat -c '%u:%a' -- "$ORM_BROKER_SOCKET" 2>/dev/null)" || return 1
            runtime_identity="$(stat -c '%u:%a' -- "$(dirname -- "$ORM_BROKER_SOCKET")" 2>/dev/null)" || return 1
            [[ "$active" == active && "$socket_identity" == 0:666 && "$runtime_identity" == 0:755 ]] && return 0
        fi
        sleep 0.1
    done
    return 1
}

orm_broker_health_matches_initial() {
    local active
    orm_broker_state_matches_initial || return 1
    active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
    [[ "$active" == "${ORM_BROKER_ACTIVE_BEFORE:-}" ]] || return 1
    [[ "$active" != active ]] || orm_wait_for_broker_socket
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
