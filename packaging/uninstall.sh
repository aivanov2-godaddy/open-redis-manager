#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/uninstall.sh\nRemoves ORM panel registrations and exact ORM-owned interface files. Redis/Valkey services, data, and configuration are not touched.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform

archive="$(mktemp "${TMPDIR:-/tmp}/orm-cpanel-plugin.XXXXXXXX.tar.gz")"
trap 'rm -f -- "$archive"' EXIT
orm_make_cpanel_archive "$archive"
orm_verify_installed_files

"$ORM_UNINSTALL_PLUGIN" "$archive" --theme="$ORM_CPanel_THEME"
rm -f -- "$ORM_CPanel_LIVE/index.live.php"
rm -f -- "$ORM_WHM_CGI/addon_open_redis_manager.php" "$ORM_WHM_ICONS/orm-whm.png" \
    "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php" \
    "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php" \
    "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php"
orm_remove_empty_owned_directories

if orm_registration_state; then "$ORM_UNREGISTER_APPCONFIG" open_redis_manager; fi
printf 'Open Redis Manager panel files and registrations removed. Redis/Valkey services, data, and configuration were left untouched.\n'
