#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/install.sh\nInstalls the ORM cPanel/WHM entries and account-scoped Redis/Valkey lifecycle adapter.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
orm_acquire_lifecycle_lock
orm_install_paths_are_clear

archive="$(mktemp "${TMPDIR:-/tmp}/orm-cpanel-plugin.XXXXXXXX.tar.gz")"
registered_cpanel=0
registered_whm=0
installed_files=0
broker_started=0
cleanup_on_error() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        if [[ "$broker_started" -eq 1 ]]; then
            "$ORM_SYSTEMCTL" disable --now orm-broker.service >/dev/null 2>&1 || true
        fi
        if [[ "$registered_whm" -eq 1 ]]; then
            "$ORM_UNREGISTER_APPCONFIG" open_redis_manager >/dev/null 2>&1 || true
        fi
        if [[ "$registered_cpanel" -eq 1 ]]; then
            "$ORM_UNINSTALL_PLUGIN" "$archive" --theme="$ORM_CPanel_THEME" >/dev/null 2>&1 || true
        fi
        if [[ "$installed_files" -eq 1 ]]; then
            local key source target mode
            while IFS='|' read -r key source target mode; do
                if [[ -f "$target" && ! -L "$target" ]] && cmp -s -- "$source" "$target"; then
                    rm -f -- "$target"
                fi
            done < <(orm_package_file_map)
            [[ ! -f "$ORM_INSTALL_MANIFEST" || -L "$ORM_INSTALL_MANIFEST" ]] || rm -f -- "$ORM_INSTALL_MANIFEST"
            "$ORM_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || true
            rmdir -- "$ORM_INSTANCE_ROOT" "$ORM_INSTANCE_DATA" 2>/dev/null || true
            orm_remove_empty_owned_directories
        fi
    fi
    rm -f -- "$archive"
    exit "$status"
}
trap cleanup_on_error EXIT

orm_make_cpanel_archive "$archive"
registered_cpanel=1
"$ORM_INSTALL_PLUGIN" "$archive" --theme "$ORM_CPanel_THEME"

umask 022
installed_files=1
orm_prepare_instance_directories
while IFS='|' read -r key source target mode; do
    if [[ "$key" == whm_appconfig ]]; then continue; fi
    [[ -f "$source" ]] || orm_die "package file is missing: $source"
    mkdir -p -- "$(dirname -- "$target")"
    install -m "$mode" "$source" "$target"
done < <(orm_package_file_map)
"$ORM_SYSTEMCTL" daemon-reload
broker_started=1
"$ORM_SYSTEMCTL" enable --now orm-broker.service
registered_whm=1
"$ORM_REGISTER_APPCONFIG" "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf"
orm_write_install_manifest "$ORM_INSTALL_MANIFEST"
printf 'Open Redis Manager installed. Account-scoped lifecycle, hourly usage history, and backup/restore controls are available; disposable-host validation is still required.\n'
