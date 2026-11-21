#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/uninstall.sh\nRemoves ORM panel registrations and exact ORM-owned files only when no managed instances exist.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
orm_acquire_lifecycle_lock "$0" "$@"
if orm_installation_is_absent; then
    if ! (
        archive="$(mktemp "${TMPDIR:-/tmp}/orm-cpanel-plugin.XXXXXXXX.tar.gz")"
        trap 'rm -f -- "$archive"' EXIT
        orm_make_cpanel_archive "$archive"
        "$ORM_UNINSTALL_PLUGIN" "$archive" --theme="$ORM_CPanel_THEME"
    ); then
        orm_die 'could not verify the already-uninstalled cPanel plugin state.'
    fi
    orm_refresh_cpanel_icon_sprite_cache_key
    printf 'Open Redis Manager is already uninstalled; no managed data or service state was changed.\n'
    exit 0
fi
if orm_instances_exist; then
    orm_die 'managed instance files exist; refusing uninstall to preserve their services, configuration, and data.'
else
    instance_check=$?
    [[ "$instance_check" -eq 1 ]] || orm_die 'could not safely verify both instance metadata and data roots; refusing uninstall.'
fi

archive="$(mktemp "${TMPDIR:-/tmp}/orm-cpanel-plugin.XXXXXXXX.tar.gz")"
backup_root=''
keep_backup=0
transaction_started=0
uninstall_succeeded=0
cpanel_changed=0
files_touched=0
whm_registered=0
broker_stopped=0
instance_roots_removed=0
provider_events_timer_stopped=0

restore_uninstalled_files() {
    local key source target mode saved rollback_failed=0
    while IFS='|' read -r key source target mode; do
        [[ "$key" == whm_appconfig ]] && continue
        if [[ -f "$backup_root/$key" && ! -L "$backup_root/$key" ]]; then
            mkdir -p -- "$(dirname -- "$target")" || { rollback_failed=1; continue; }
            saved="$(mktemp "$(dirname -- "$target")/.orm-rollback.XXXXXXXX")" || { rollback_failed=1; continue; }
            cp -a -- "$backup_root/$key" "$saved" && mv -f -- "$saved" "$target" || rollback_failed=1
        elif [[ -e "$target" || -L "$target" ]]; then
            if [[ -f "$target" && ! -L "$target" ]] && cmp -s -- "$source" "$target"; then
                rm -f -- "$target" || rollback_failed=1
            else
                rollback_failed=1
            fi
        fi
    done < <(orm_package_file_map)

    if [[ -f "$backup_root/install_manifest" && ! -L "$backup_root/install_manifest" ]]; then
        saved="$(mktemp "$(dirname -- "$ORM_INSTALL_MANIFEST")/.orm-rollback.XXXXXXXX")" || rollback_failed=1
        if [[ -n "$saved" ]]; then
            cp -a -- "$backup_root/install_manifest" "$saved" && mv -f -- "$saved" "$ORM_INSTALL_MANIFEST" || rollback_failed=1
        fi
    elif [[ -e "$ORM_INSTALL_MANIFEST" || -L "$ORM_INSTALL_MANIFEST" ]]; then
        rm -f -- "$ORM_INSTALL_MANIFEST" || rollback_failed=1
    fi
    return "$rollback_failed"
}

rollback_uninstall() {
    local rollback_failed=0 registration_status
    if [[ "$files_touched" -eq 1 ]]; then
        restore_uninstalled_files || rollback_failed=1
    fi
    if [[ "$cpanel_changed" -eq 1 ]]; then
        if "$ORM_INSTALL_PLUGIN" "$archive" --theme "$ORM_CPanel_THEME" >/dev/null 2>&1; then
            orm_refresh_cpanel_icon_sprite_cache_key
        else
            rollback_failed=1
        fi
    fi
    if [[ "$whm_registered" -eq 1 ]]; then
        if orm_registration_state; then
            if [[ ! -f "$ORM_APPCONFIG" || -L "$ORM_APPCONFIG" ]]; then
                "$ORM_UNREGISTER_APPCONFIG" open_redis_manager >/dev/null 2>&1 || rollback_failed=1
                "$ORM_REGISTER_APPCONFIG" "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" >/dev/null 2>&1 || rollback_failed=1
            fi
        else
            registration_status=$?
            if [[ "$registration_status" -eq 1 ]]; then
                if [[ -f "$ORM_APPCONFIG" && ! -L "$ORM_APPCONFIG" ]]; then
                    "$ORM_REGISTER_APPCONFIG" "$ORM_APPCONFIG" >/dev/null 2>&1 || rollback_failed=1
                else
                    "$ORM_REGISTER_APPCONFIG" "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" >/dev/null 2>&1 || rollback_failed=1
                fi
            else
                rollback_failed=1
            fi
        fi
        orm_registration_state || rollback_failed=1
        orm_appconfig_matches_package "$ORM_APPCONFIG" || rollback_failed=1
    fi
    if [[ "$instance_roots_removed" -eq 1 ]]; then
        orm_restore_empty_instance_directories || rollback_failed=1
    fi
    if [[ "$files_touched" -eq 1 ]]; then
        "$ORM_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "$provider_events_timer_stopped" -eq 1 ]]; then
        "$ORM_SYSTEMCTL" enable --now orm-provider-events.timer >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "$rollback_failed" -eq 0 ]]; then
        if [[ "$broker_stopped" -eq 1 ]] || ! orm_broker_state_matches_initial; then
            orm_restore_broker_state >/dev/null 2>&1 || rollback_failed=1
        fi
        if [[ "$rollback_failed" -eq 0 && "$ORM_BROKER_ACTIVE_BEFORE" == active ]]; then
            orm_wait_for_broker_socket || rollback_failed=1
        fi
    elif [[ -f "$ORM_BROKER_UNIT" ]]; then
        "$ORM_SYSTEMCTL" disable --now orm-broker.service >/dev/null 2>&1 || true
    fi
    if [[ "$rollback_failed" -ne 0 ]]; then
        printf 'ORM uninstaller: rollback was incomplete; the broker was left in its current state. Recovery files retained at %s.\n' "$backup_root" >&2
        return 1
    fi
    printf 'ORM uninstaller: the installation and service state were restored after the uninstall stopped early.\n' >&2
}

cleanup_on_exit() {
    local status=$?
    if [[ "$status" -ne 0 && "$uninstall_succeeded" -eq 0 && "$transaction_started" -eq 1 ]]; then
        if ! rollback_uninstall; then
            status=1
            keep_backup=1
        fi
    fi
    rm -f -- "$archive"
    if [[ -n "$backup_root" && "$keep_backup" -ne 1 ]]; then rm -rf -- "$backup_root"; fi
    exit "$status"
}
trap cleanup_on_exit EXIT

orm_make_cpanel_archive "$archive"
if [[ -e "$ORM_INSTALL_MANIFEST" || -L "$ORM_INSTALL_MANIFEST" ]]; then
    orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
        || orm_die 'the install manifest or an ORM-owned installed file failed integrity validation.'
fi
orm_verify_installed_files
if orm_registration_state; then
    whm_registered=1
    [[ -f "$ORM_APPCONFIG" && ! -L "$ORM_APPCONFIG" ]] \
        || orm_die 'WHM reports ORM registered but its AppConfig file is missing or unsafe.'
    orm_appconfig_matches_package "$ORM_APPCONFIG" \
        || orm_die 'the registered WHM AppConfig file differs from this package; refusing uninstall.'
else
    registration_status=$?
    [[ "$registration_status" -eq 1 ]] || orm_die 'could not safely verify WHM AppConfig registration.'
    [[ ! -e "$ORM_APPCONFIG" && ! -L "$ORM_APPCONFIG" ]] \
        || orm_die 'an unregistered WHM AppConfig file remains; refusing to leave or remove an ambiguous registration.'
fi

orm_capture_broker_state || orm_die 'could not determine the broker state; refusing uninstall.'
backup_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-uninstall.XXXXXXXX")"
chmod 0700 -- "$backup_root"
while IFS='|' read -r key source target mode; do
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] || orm_die "refusing to back up an unsafe ORM path: $target"
        cp -a -- "$target" "$backup_root/$key"
    fi
done < <(orm_package_file_map)
if [[ -e "$ORM_INSTALL_MANIFEST" ]]; then cp -a -- "$ORM_INSTALL_MANIFEST" "$backup_root/install_manifest"; fi
transaction_started=1

if [[ -f "$ORM_BROKER_UNIT" ]]; then
    stop_status=0
    "$ORM_SYSTEMCTL" disable --now orm-broker.service || stop_status=$?
    stopped_enabled="$("$ORM_SYSTEMCTL" is-enabled orm-broker.service 2>/dev/null || true)"
    stopped_active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
    if [[ "$stopped_enabled" != "${ORM_BROKER_ENABLED_BEFORE:-}" \
        || ( "$stopped_active" != "${ORM_BROKER_ACTIVE_BEFORE:-}" ) ]]; then broker_stopped=1; fi
    [[ "$stop_status" -eq 0 ]] || exit "$stop_status"
    broker_stopped=1
    [[ "$stopped_enabled" == disabled && ( "$stopped_active" == inactive || "$stopped_active" == failed ) ]] \
        || orm_die 'could not stop and disable the broker; no package files were removed.'
fi

if [[ -f "$ORM_PROVIDER_EVENTS_TIMER" ]]; then
    timer_enabled="$("$ORM_SYSTEMCTL" is-enabled orm-provider-events.timer 2>/dev/null || true)"
    timer_active="$("$ORM_SYSTEMCTL" is-active orm-provider-events.timer 2>/dev/null || true)"
    case "$timer_enabled" in enabled|disabled|enabled-runtime) ;; *) orm_die 'could not determine provider event timer state; refusing uninstall.' ;; esac
    case "$timer_active" in active|inactive|failed) ;; *) orm_die 'could not determine provider event timer activity; refusing uninstall.' ;; esac
    if [[ "$timer_enabled" == enabled || "$timer_enabled" == enabled-runtime || "$timer_active" == active ]]; then
        "$ORM_SYSTEMCTL" disable --now orm-provider-events.timer || orm_die 'could not stop the provider event timer; no files were removed.'
        "$ORM_SYSTEMCTL" stop orm-provider-events.service >/dev/null 2>&1 || true
        provider_events_timer_stopped=1
    fi
fi

if orm_instances_exist; then
    orm_die 'an instance appeared during uninstall preflight; no files were removed.'
else
    instance_check=$?
    [[ "$instance_check" -eq 1 ]] || orm_die 'could not safely recheck the instance roots; no files were removed.'
fi

cpanel_changed=1
"$ORM_UNINSTALL_PLUGIN" "$archive" --theme="$ORM_CPanel_THEME"
orm_refresh_cpanel_icon_sprite_cache_key
files_touched=1
while IFS='|' read -r key source target mode; do
    [[ "$key" == whm_appconfig ]] && continue
    rm -f -- "$target"
done < <(orm_package_file_map)
rm -f -- "$ORM_INSTALL_MANIFEST"
"$ORM_SYSTEMCTL" daemon-reload

if [[ "$whm_registered" -eq 1 ]]; then
    "$ORM_UNREGISTER_APPCONFIG" open_redis_manager
    if orm_registration_state; then
        orm_die 'WHM still reports ORM registered after unregister_appconfig.'
    else
        registration_status=$?
        [[ "$registration_status" -eq 1 ]] || orm_die 'could not verify WHM AppConfig unregistration.'
    fi
    [[ ! -e "$ORM_APPCONFIG" && ! -L "$ORM_APPCONFIG" ]] || rm -f -- "$ORM_APPCONFIG"
fi

orm_remove_empty_owned_directories
instance_roots_removed=1
orm_remove_empty_instance_directories \
    || orm_die 'could not remove the empty, root-owned ORM instance directories.'
uninstall_succeeded=1
transaction_started=0
printf 'Open Redis Manager panel files and registrations removed. Redis/Valkey services, data, and configuration were left untouched.\n'
