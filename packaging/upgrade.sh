#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/upgrade.sh\nUpgrades only the verified identity-only ORM v1 install to this repository revision.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
orm_acquire_lifecycle_lock

[[ ! -e "$ORM_INSTALL_MANIFEST" && ! -L "$ORM_INSTALL_MANIFEST" ]] \
    || orm_die 'this install already has a managed manifest; this bridge only upgrades the verified identity-only v1 install.'
orm_validate_legacy_identity_v1 \
    || orm_die 'installed files do not exactly match the supported identity-only v1 baseline; no files were changed.'

for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
    [[ ! -e "$path" && ! -L "$path" ]] \
        || orm_die "the identity-only v1 upgrade requires absent instance roots; refusing to touch: $path"
done

[[ -f "$ORM_APPCONFIG" && ! -L "$ORM_APPCONFIG" ]] \
    || orm_die 'the registered WHM AppConfig file is missing or unsafe.'
appconfig_owner="$(stat -c '%u' -- "$ORM_APPCONFIG")"
appconfig_mode="$(stat -c '%a' -- "$ORM_APPCONFIG")"
[[ "$appconfig_owner" == 0 ]] && (( (8#$appconfig_mode & 0022) == 0 )) \
    || orm_die 'the registered WHM AppConfig file has unsafe ownership or permissions.'
cmp -s -- "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" "$ORM_APPCONFIG" \
    || orm_die 'the registered WHM AppConfig file differs from the supported v1 baseline.'
if orm_registration_state; then
    :
else
    registration_status=$?
    [[ "$registration_status" -eq 1 ]] \
        || orm_die 'could not safely verify the WHM AppConfig registration state.'
    orm_die 'the WHM AppConfig registration is missing; refusing an incomplete install.'
fi

declare -A legacy_targets=()
while IFS='|' read -r key target mode; do legacy_targets[$target]=1; done < <(orm_legacy_identity_v1_file_map)
while IFS='|' read -r key source target mode; do
    [[ -f "$source" && ! -L "$source" ]] || orm_die "package file is missing or unsafe: $source"
    if [[ -n "${legacy_targets[$target]+present}" ]]; then
        continue
    fi
    [[ ! -e "$target" && ! -L "$target" ]] \
        || orm_die "an unexpected ORM target already exists; refusing to overwrite it: $target"
done < <(orm_package_file_map)

if [[ -d "$ORM_3RDPARTY" && ! -L "$ORM_3RDPARTY" ]]; then
    while IFS= read -r path; do
        [[ -n "${legacy_targets[$path]+present}" ]] \
            || orm_die "an unmanifested file exists in the ORM package directory: $path"
    done < <(find "$ORM_3RDPARTY" -type f -o -type l)
else
    orm_die 'the expected ORM package directory is missing or unsafe.'
fi
package_root_owner="$(stat -c '%u' -- "$ORM_3RDPARTY")"
package_root_mode="$(stat -c '%a' -- "$ORM_3RDPARTY")"
[[ "$package_root_owner" == 0 ]] && (( (8#$package_root_mode & 0022) == 0 )) \
    || orm_die 'the ORM package directory has unsafe ownership or permissions.'
if [[ -d "$ORM_CPanel_LIVE" && ! -L "$ORM_CPanel_LIVE" ]]; then
    unexpected_cpanel_file="$(find "$ORM_CPanel_LIVE" -mindepth 1 ! -path "$ORM_CPanel_LIVE/index.live.php" -print -quit)"
    [[ -z "$unexpected_cpanel_file" ]] \
        || orm_die "an unmanifested file exists in the cPanel ORM directory: $unexpected_cpanel_file"
else
    orm_die 'the expected cPanel ORM directory is missing or unsafe.'
fi

orm_capture_broker_state || orm_die 'could not determine the broker enabled and active state.'
if [[ "$ORM_BROKER_ACTIVE_BEFORE" == active ]]; then
    command -v ss >/dev/null 2>&1 || orm_die 'ss is required to drain broker requests without interrupting active operations.'
    [[ -S "$ORM_BROKER_SOCKET" && ! -L "$ORM_BROKER_SOCKET" ]] \
        || orm_die 'the active broker socket is missing or unsafe.'
    socket_identity="$(stat -c '%u:%a' -- "$ORM_BROKER_SOCKET")"
    runtime_identity="$(stat -c '%u:%a' -- "$(dirname -- "$ORM_BROKER_SOCKET")")"
    [[ "$socket_identity" == 0:666 && "$runtime_identity" == 0:755 ]] \
        || orm_die 'the active broker socket or runtime directory has unexpected ownership or permissions.'
elif [[ -e "$ORM_BROKER_SOCKET" || -L "$ORM_BROKER_SOCKET" ]]; then
    orm_die 'a broker socket exists while the broker service is inactive; refusing to replace a stale socket.'
fi

umask 077
backup_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-upgrade.XXXXXXXX")"
current_archive="$(mktemp "${TMPDIR:-/tmp}/orm-current-plugin.XXXXXXXX.tar.gz")"
legacy_archive="$(mktemp "${TMPDIR:-/tmp}/orm-legacy-plugin.XXXXXXXX.tar.gz")"
cpanel_changed=0
broker_stopped=0
socket_quarantined=0
files_touched=0
upgrade_succeeded=0
quarantine_path=''

rollback_upgrade() {
    local rollback_failed=0 key source target mode saved current_active
    if [[ "$broker_stopped" -eq 1 ]]; then
        if ! "$ORM_SYSTEMCTL" stop orm-broker.service >/dev/null 2>&1; then
            printf 'ORM upgrader: rollback could not stop the broker; package restoration was not attempted.\n' >&2
            return 1
        fi
        current_active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
        if [[ "$current_active" != inactive && "$current_active" != failed ]]; then
            printf 'ORM upgrader: rollback could not confirm the broker stopped; package restoration was not attempted.\n' >&2
            return 1
        fi
    elif [[ "$socket_quarantined" -eq 1 && -S "$quarantine_path" && ! -e "$ORM_BROKER_SOCKET" ]]; then
        chmod 0666 -- "$quarantine_path" || rollback_failed=1
        mv -- "$quarantine_path" "$ORM_BROKER_SOCKET" || rollback_failed=1
        socket_quarantined=0
    fi
    if [[ "$files_touched" -eq 1 ]]; then
        while IFS='|' read -r key source target mode; do
            if [[ -f "$backup_root/$key" && ! -L "$backup_root/$key" ]]; then
                mkdir -p -- "$(dirname -- "$target")" || rollback_failed=1
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
        [[ ! -f "$ORM_INSTALL_MANIFEST" || -L "$ORM_INSTALL_MANIFEST" ]] || rm -f -- "$ORM_INSTALL_MANIFEST" || rollback_failed=1
    fi
    if [[ "$cpanel_changed" -eq 1 ]]; then
        "$ORM_UNINSTALL_PLUGIN" "$current_archive" --theme="$ORM_CPanel_THEME" >/dev/null 2>&1 || rollback_failed=1
        "$ORM_INSTALL_PLUGIN" "$legacy_archive" --theme "$ORM_CPanel_THEME" >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "$files_touched" -eq 1 || "$broker_stopped" -eq 1 ]]; then
        "$ORM_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "$rollback_failed" -eq 0 && "$ORM_BROKER_ACTIVE_BEFORE" == active ]]; then
        current_active="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
        case "$current_active" in
            active) ;;
            inactive|failed) "$ORM_SYSTEMCTL" start orm-broker.service >/dev/null 2>&1 || rollback_failed=1 ;;
            *) rollback_failed=1 ;;
        esac
    fi
    if [[ "$rollback_failed" -ne 0 ]]; then
        printf 'ORM upgrader: rollback was incomplete; the broker was left stopped. Keep the instance roots untouched and inspect cPanel registration and ORM package files before use.\n' >&2
        return 1
    fi
    printf 'ORM upgrader: the verified identity-only v1 installation was restored.\n' >&2
}

cleanup_upgrade() {
    local status=$?
    if [[ "$status" -ne 0 && "$upgrade_succeeded" -eq 0 ]]; then
        rollback_upgrade || status=1
    fi
    rm -f -- "$current_archive" "$legacy_archive"
    [[ -z "${temporary:-}" || ! -f "$temporary" || -L "$temporary" ]] || rm -f -- "$temporary"
    [[ ! -f "${ORM_INSTALL_MANIFEST}.tmp.$$" || -L "${ORM_INSTALL_MANIFEST}.tmp.$$" ]] \
        || rm -f -- "${ORM_INSTALL_MANIFEST}.tmp.$$"
    rm -rf -- "$backup_root"
    exit "$status"
}
trap cleanup_upgrade EXIT

orm_make_cpanel_archive "$current_archive"
orm_make_legacy_identity_v1_cpanel_archive "$legacy_archive"
while IFS='|' read -r key target mode; do
    [[ -f "$target" && ! -L "$target" ]] || orm_die "legacy file changed after preflight: $target"
    cp -a -- "$target" "$backup_root/$key"
done < <(orm_legacy_identity_v1_file_map)

if [[ "$ORM_BROKER_ACTIVE_BEFORE" == active ]]; then
    broker_pid="$("$ORM_SYSTEMCTL" show -p MainPID --value orm-broker.service 2>/dev/null)"
    [[ "$broker_pid" =~ ^[1-9][0-9]*$ ]] || orm_die 'could not identify the active broker process.'
    quarantine_path="${ORM_BROKER_SOCKET}.orm-upgrade-${broker_pid}"
    [[ ! -e "$quarantine_path" && ! -L "$quarantine_path" ]] || orm_die 'the broker socket quarantine path already exists.'
    mv -- "$ORM_BROKER_SOCKET" "$quarantine_path"
    socket_quarantined=1
    chmod 0600 -- "$quarantine_path"
    # The supported identity-only v1 server expires idle clients after 1.5 seconds.
    # Keep the listener alive past that deadline after unlinking the public socket path.
    sleep 2
    stable_idle=0
    for ((attempt = 0; attempt < 1200; attempt++)); do
        active_connections="$(ss -xapn state established 2>/dev/null | awk -v token="pid=${broker_pid}," 'index($0, token) { count++ } END { print count + 0 }')" \
            || orm_die 'could not inspect broker connections; the socket remains quarantined.'
        queued_connections="$(ss -xlpH 2>/dev/null | awk -v token="pid=${broker_pid}," 'index($0, token) && $2 == "LISTEN" { count += $3 } END { print count + 0 }')" \
            || orm_die 'could not inspect the broker accept queue; the socket remains quarantined.'
        if [[ "$active_connections" == 0 && "$queued_connections" == 0 ]]; then
            ((stable_idle += 1))
            [[ "$stable_idle" -ge 3 ]] && break
        else
            stable_idle=0
        fi
        sleep 0.1
    done
    [[ "$stable_idle" -ge 3 ]] || orm_die 'broker requests did not drain within 120 seconds; no package files were changed.'
    "$ORM_SYSTEMCTL" stop orm-broker.service
    broker_stopped=1
    stopped_state="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
    [[ "$stopped_state" == inactive || "$stopped_state" == failed ]] \
        || orm_die 'the broker did not stop after its connections drained.'
    [[ ! -e "$ORM_BROKER_SOCKET" && ! -L "$ORM_BROKER_SOCKET" ]] \
        || orm_die 'the broker socket path was recreated during shutdown.'
    [[ ! -e "$quarantine_path" && ! -L "$quarantine_path" ]] || rm -f -- "$quarantine_path"
    socket_quarantined=0
fi

cpanel_changed=1
"$ORM_UNINSTALL_PLUGIN" "$current_archive" --theme="$ORM_CPanel_THEME"
"$ORM_INSTALL_PLUGIN" "$current_archive" --theme "$ORM_CPanel_THEME"
files_touched=1
while IFS='|' read -r key source target mode; do
    mkdir -p -- "$(dirname -- "$target")"
    temporary="$(mktemp "$(dirname -- "$target")/.orm-upgrade.XXXXXXXX")"
    install -m "$mode" "$source" "$temporary"
    chown root:root -- "$temporary"
    mv -f -- "$temporary" "$target"
    temporary=''
done < <(orm_package_file_map)
orm_write_install_manifest "$ORM_INSTALL_MANIFEST"
"$ORM_SYSTEMCTL" daemon-reload
if [[ "$ORM_BROKER_ACTIVE_BEFORE" == active ]]; then
    "$ORM_SYSTEMCTL" start orm-broker.service
fi

orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
    || orm_die 'the upgraded file manifest failed validation.'
cmp -s -- "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf" "$ORM_APPCONFIG" \
    || orm_die 'the registered WHM AppConfig changed during upgrade.'
orm_registration_state || orm_die 'the WHM AppConfig registration is missing after upgrade.'
orm_broker_state_matches_initial || orm_die 'the broker enabled or active state changed during upgrade.'
if [[ "$ORM_BROKER_ACTIVE_BEFORE" == active ]]; then
    [[ -S "$ORM_BROKER_SOCKET" && ! -L "$ORM_BROKER_SOCKET" ]] \
        || orm_die 'the upgraded broker did not recreate its Unix socket.'
fi

upgrade_succeeded=1
printf 'Open Redis Manager identity-only v1 installation upgraded. The broker service state was preserved; instance roots were not created or changed.\n'
