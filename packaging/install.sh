#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/install.sh\nInstalls the ORM cPanel Jupiter link and root-only WHM discovery page.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
orm_install_paths_are_clear

archive="$(mktemp "${TMPDIR:-/tmp}/orm-cpanel-plugin.XXXXXXXX.tar.gz")"
registered_cpanel=0
registered_whm=0
installed_files=0
cleanup_on_error() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        if [[ "$registered_whm" -eq 1 ]]; then
            "$ORM_UNREGISTER_APPCONFIG" open_redis_manager >/dev/null 2>&1 || true
        fi
        if [[ "$registered_cpanel" -eq 1 ]]; then
            "$ORM_UNINSTALL_PLUGIN" "$archive" --theme="$ORM_CPanel_THEME" >/dev/null 2>&1 || true
        fi
        if [[ "$installed_files" -eq 1 ]]; then
            rm -f -- "$ORM_WHM_CGI/addon_open_redis_manager.php" "$ORM_WHM_ICONS/orm-whm.png" \
                "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php" \
                "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php" "$ORM_CPanel_LIVE/index.live.php"
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
mkdir -p -- "$ORM_CPanel_LIVE" "$ORM_WHM_CGI" "$ORM_WHM_ICONS" \
    "$ORM_3RDPARTY/src/Orm/Backend" "$ORM_3RDPARTY/src/Orm/Security"
installed_files=1
install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/files/orm/index.live.php" "$ORM_CPanel_LIVE/index.live.php"
install -m 0644 "$ORM_PACKAGE_ROOT/whm/cgi/addon_open_redis_manager.php" "$ORM_WHM_CGI/addon_open_redis_manager.php"
install -m 0644 "$ORM_PACKAGE_ROOT/whm/icons/orm-whm.png" "$ORM_WHM_ICONS/orm-whm.png"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Backend/BackendDiscovery.php" "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Security/WhmAcl.php" "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php"
registered_whm=1
"$ORM_REGISTER_APPCONFIG" "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf"
printf 'Open Redis Manager installed. The current UI provides read-only WHM backend discovery; account management is not implemented yet.\n'
