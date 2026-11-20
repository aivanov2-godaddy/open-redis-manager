#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/upgrade.sh\nUpgrades only an exact supported ORM v1 install to this repository revision.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
orm_acquire_lifecycle_lock "$0" "$@"

legacy_install_kind=identity
if [[ -e "$ORM_INSTALL_MANIFEST" || -L "$ORM_INSTALL_MANIFEST" ]]; then
    orm_validate_legacy_managed_v1 \
        || orm_die 'the installed managed v1 package does not exactly match the supported baseline; no files were changed.'
    legacy_install_kind=managed
else
    orm_validate_legacy_identity_v1 \
        || orm_die 'installed files do not exactly match the supported identity-only v1 baseline; no files were changed.'
    for path in "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA"; do
        [[ ! -e "$path" && ! -L "$path" ]] \
            || orm_die "the identity-only v1 upgrade requires absent instance roots; refusing to touch: $path"
    done
fi

[[ -f "$ORM_APPCONFIG" && ! -L "$ORM_APPCONFIG" ]] \
    || orm_die 'the registered WHM AppConfig file is missing or unsafe.'
appconfig_owner="$(stat -c '%u' -- "$ORM_APPCONFIG")"
appconfig_mode="$(stat -c '%a' -- "$ORM_APPCONFIG")"
[[ "$appconfig_owner" == 0 ]] && (( (8#$appconfig_mode & 0022) == 0 )) \
    || orm_die 'the registered WHM AppConfig file has unsafe ownership or permissions.'
if [[ "$legacy_install_kind" == identity ]]; then
    orm_appconfig_matches_package "$ORM_APPCONFIG" \
        || orm_die 'the registered WHM AppConfig file differs from the supported v1 baseline.'
fi
if orm_registration_state; then
    :
else
    registration_status=$?
    [[ "$registration_status" -eq 1 ]] \
        || orm_die 'could not safely verify the WHM AppConfig registration state.'
    orm_die 'the WHM AppConfig registration is missing; refusing an incomplete install.'
fi

declare -A legacy_targets=()
if [[ "$legacy_install_kind" == managed ]]; then
    while IFS='|' read -r key source target mode expected_digest; do legacy_targets[$target]=1; done \
        < <(orm_legacy_managed_v1_file_map)
    legacy_targets[$ORM_INSTALL_MANIFEST]=1
else
    while IFS='|' read -r key target mode; do legacy_targets[$target]=1; done \
        < <(orm_legacy_identity_v1_file_map)
fi
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
managed_legacy_archive="$(mktemp "${TMPDIR:-/tmp}/orm-managed-legacy-plugin.XXXXXXXX.tar.gz")"
rollback_archive="$legacy_archive"
cpanel_changed=0
broker_stopped=0
socket_quarantined=0
instance_roots_prepared=0
files_touched=0
upgrade_succeeded=0
keep_backup=0
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
        if [[ -n "${temporary:-}" ]]; then
            if [[ -f "$temporary" && ! -L "$temporary" ]]; then
                rm -f -- "$temporary" || rollback_failed=1
            elif [[ -e "$temporary" || -L "$temporary" ]]; then
                rollback_failed=1
            fi
            temporary=''
        fi
        while IFS='|' read -r key source target mode; do
            [[ "$key" == whm_appconfig ]] && continue
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
        if [[ "$legacy_install_kind" == managed ]]; then
            if [[ -f "$backup_root/install-manifest-v1" && ! -L "$backup_root/install-manifest-v1" ]]; then
                saved="$(mktemp "$(dirname -- "$ORM_INSTALL_MANIFEST")/.orm-rollback-manifest.XXXXXXXX")" \
                    || { rollback_failed=1; saved=''; }
                if [[ -n "$saved" ]]; then
                    cp -a -- "$backup_root/install-manifest-v1" "$saved" \
                        && mv -f -- "$saved" "$ORM_INSTALL_MANIFEST" || rollback_failed=1
                fi
            else
                rollback_failed=1
            fi
            if [[ -f "$backup_root/whm_appconfig" && ! -L "$backup_root/whm_appconfig" ]] \
                && ! cmp -s -- "$backup_root/whm_appconfig" "$ORM_APPCONFIG"; then
                saved="$(mktemp "$(dirname -- "$ORM_APPCONFIG")/.orm-rollback-appconfig.XXXXXXXX")" \
                    || { rollback_failed=1; saved=''; }
                if [[ -n "$saved" ]]; then
                    cp -a -- "$backup_root/whm_appconfig" "$saved" \
                        && mv -f -- "$saved" "$ORM_APPCONFIG" || rollback_failed=1
                fi
            fi
            orm_remove_upgrade_created_managed_directories \
                "$backup_root/managed-directory-created-v1" \
                || { printf 'ORM upgrader: rollback could not remove a transaction-created empty directory.\n' >&2; rollback_failed=1; }
        else
            [[ ! -f "$ORM_INSTALL_MANIFEST" || -L "$ORM_INSTALL_MANIFEST" ]] \
                || rm -f -- "$ORM_INSTALL_MANIFEST" || rollback_failed=1
        fi
    fi
    if [[ "$cpanel_changed" -eq 1 ]]; then
        "$ORM_INSTALL_PLUGIN" "$rollback_archive" --theme "$ORM_CPanel_THEME" >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "$legacy_install_kind" == managed ]]; then
        orm_validate_legacy_managed_v1 \
            || { printf 'ORM upgrader: rollback did not restore the exact managed v1 baseline.\n' >&2; rollback_failed=1; }
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
        if [[ "$rollback_failed" -eq 0 ]]; then
            orm_wait_for_broker_socket || rollback_failed=1
        fi
    fi
    if [[ "$rollback_failed" -eq 0 && "$instance_roots_prepared" -eq 1 ]]; then
        orm_remove_prepared_instance_directories || rollback_failed=1
    fi
    if [[ "$rollback_failed" -ne 0 ]]; then
        printf 'ORM upgrader: rollback was incomplete; keep any instance roots and recovery data untouched while inspecting cPanel registration and ORM package files.\n' >&2
        return 1
    fi
    if [[ "$legacy_install_kind" == managed ]]; then
        printf 'ORM upgrader: the verified managed v1 installation was restored.\n' >&2
    else
        printf 'ORM upgrader: the verified identity-only v1 installation was restored.\n' >&2
    fi
}

cleanup_upgrade() {
    local status=$?
    trap - INT TERM
    if [[ "$status" -ne 0 && "$upgrade_succeeded" -eq 0 ]]; then
        if ! rollback_upgrade; then
            status=1
            keep_backup=1
            printf 'ORM upgrader: recovery files retained at %s\n' "$backup_root" >&2
        fi
    fi
    rm -f -- "$current_archive" "$legacy_archive"
    rm -f -- "$managed_legacy_archive"
    [[ -z "${temporary:-}" || ! -f "$temporary" || -L "$temporary" ]] || rm -f -- "$temporary"
    [[ ! -f "${ORM_INSTALL_MANIFEST}.tmp.$$" || -L "${ORM_INSTALL_MANIFEST}.tmp.$$" ]] \
        || rm -f -- "${ORM_INSTALL_MANIFEST}.tmp.$$"
    [[ "$keep_backup" -eq 1 ]] || rm -rf -- "$backup_root"
    exit "$status"
}
trap cleanup_upgrade EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

orm_make_cpanel_archive "$current_archive"
orm_make_legacy_identity_v1_cpanel_archive "$legacy_archive"
if [[ "$legacy_install_kind" == managed ]]; then
    orm_make_legacy_managed_v1_cpanel_archive "$managed_legacy_archive"
    rollback_archive="$managed_legacy_archive"
    while IFS='|' read -r key source target mode expected_digest; do
        [[ -f "$target" && ! -L "$target" ]] || orm_die 'a managed v1 package file changed after preflight.'
        cp -a -- "$target" "$backup_root/$key"
    done < <(orm_legacy_managed_v1_file_map)
    cp -a -- "$ORM_INSTALL_MANIFEST" "$backup_root/install-manifest-v1"
    find "$ORM_3RDPARTY" -mindepth 1 -type d -print | LC_ALL=C sort \
        >"$backup_root/managed-directory-inventory-v1"
    : >"$backup_root/managed-directory-created-v1"
else
    while IFS='|' read -r key target mode; do
        [[ -f "$target" && ! -L "$target" ]] || orm_die "legacy file changed after preflight: $target"
        cp -a -- "$target" "$backup_root/$key"
    done < <(orm_legacy_identity_v1_file_map)
fi

instance_roots_prepared=1
if [[ "$legacy_install_kind" == managed ]]; then
    orm_prepare_upgrade_instance_directories
else
    orm_prepare_instance_directories
fi

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
    drain_started="$SECONDS"
    while (( SECONDS - drain_started < 120 )); do
        active_connections="$(ss -xapn state established 2>/dev/null | awk -v token="pid=${broker_pid}," '
            function has_client_fd(line, field, fd) {
                while (match(line, /pid=[0-9]+,fd=[0-9]+/)) {
                    field = substr(line, RSTART, RLENGTH)
                    sub(/^.*fd=/, "", field)
                    sub(/[^0-9].*$/, "", field)
                    fd = field + 0
                    if (fd > 2) return 1
                    line = substr(line, RSTART + RLENGTH)
                }
                return 0
            }
            index($0, token) && has_client_fd($0) { count++ }
            END { print count + 0 }
        ')" \
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
"$ORM_INSTALL_PLUGIN" "$current_archive" --theme "$ORM_CPanel_THEME"
files_touched=1
while IFS='|' read -r key source target mode; do
    # register_appconfig owns this file; it was validated and is included in the manifest,
    # but cPanel recommends changing AppConfig only through its utilities.
    [[ "$key" == whm_appconfig ]] && continue
    mkdir -p -- "$(dirname -- "$target")"
    if [[ "$legacy_install_kind" == managed ]]; then
        orm_record_upgrade_created_managed_directories \
            "$backup_root/managed-directory-inventory-v1" \
            "$backup_root/managed-directory-created-v1" \
            || orm_die 'could not track transaction-created ORM package directories.'
    fi
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
    orm_wait_for_broker_socket \
        || orm_die 'the upgraded broker did not become ready with its expected Unix socket.'
fi

orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
    || orm_die 'the upgraded file manifest failed validation.'
if [[ "$legacy_install_kind" == managed ]]; then
    cmp -s -- "$backup_root/whm_appconfig" "$ORM_APPCONFIG" \
        || orm_die 'the registered WHM AppConfig changed during upgrade.'
else
    orm_appconfig_matches_package "$ORM_APPCONFIG" \
        || orm_die 'the registered WHM AppConfig changed during upgrade.'
fi
orm_registration_state || orm_die 'the WHM AppConfig registration is missing after upgrade.'
if ! orm_broker_state_matches_initial; then
    enabled_after="$("$ORM_SYSTEMCTL" is-enabled orm-broker.service 2>/dev/null || true)"
    active_after="$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)"
    orm_die "broker state changed (expected enabled=$ORM_BROKER_ENABLED_BEFORE, active=$ORM_BROKER_ACTIVE_BEFORE; observed enabled=$enabled_after, active=$active_after)."
fi
upgrade_succeeded=1
if [[ "$legacy_install_kind" == managed ]]; then
    printf 'Open Redis Manager managed v1 installation upgraded. Broker state, existing instance data, and cPanel-managed containers were preserved.\n'
else
    printf 'Open Redis Manager identity-only v1 installation upgraded. Broker state was preserved; only empty, root-owned instance roots were prepared.\n'
fi
