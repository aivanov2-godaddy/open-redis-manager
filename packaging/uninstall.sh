#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/uninstall.sh\nRemoves ORM panel registrations and exact ORM-owned files only when no managed instances exist.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
if orm_instances_exist; then
    orm_die 'managed instance files exist; refusing uninstall to preserve their services, configuration, and data.'
else
    instance_check=$?
    [[ "$instance_check" -eq 1 ]] || orm_die 'could not safely verify both instance metadata and data roots; refusing uninstall.'
fi

archive="$(mktemp "${TMPDIR:-/tmp}/orm-cpanel-plugin.XXXXXXXX.tar.gz")"
restore_broker_on_exit=0
cleanup_on_exit() {
    local status=$?
    if [[ "$status" -ne 0 && "$restore_broker_on_exit" -eq 1 && -f "$ORM_BROKER_UNIT" ]]; then
        if orm_restore_broker_state >/dev/null 2>&1; then
            restore_broker_on_exit=0
            printf 'ORM uninstaller: broker state restored after the uninstall stopped early.\n' >&2
        else
            printf 'ORM uninstaller: broker state restoration failed; inspect orm-broker.service before using ORM.\n' >&2
        fi
    fi
    rm -f -- "$archive"
    exit "$status"
}
trap cleanup_on_exit EXIT
orm_make_cpanel_archive "$archive"
orm_verify_installed_files

broker_stopped=0
if [[ -f "$ORM_BROKER_UNIT" ]]; then
    orm_capture_broker_state || orm_die 'could not determine the broker state; refusing uninstall.'
    stop_status=0
    "$ORM_SYSTEMCTL" disable --now orm-broker.service || stop_status=$?
    if ! orm_broker_state_matches_initial; then restore_broker_on_exit=1; fi
    [[ "$stop_status" -eq 0 ]] || exit "$stop_status"
    broker_stopped=1
fi
if orm_instances_exist; then
    if [[ "$broker_stopped" -eq 1 ]]; then
        if orm_restore_broker_state >/dev/null 2>&1; then
            restore_broker_on_exit=0
        fi
    fi
    orm_die 'an instance appeared during uninstall preflight; no files were removed.'
else
    instance_check=$?
    if [[ "$instance_check" -ne 1 ]]; then
        if [[ "$broker_stopped" -eq 1 ]]; then
            if orm_restore_broker_state >/dev/null 2>&1; then
                restore_broker_on_exit=0
            fi
        fi
        orm_die 'could not safely recheck the instance roots; no files were removed.'
    fi
fi
"$ORM_UNINSTALL_PLUGIN" "$archive" --theme="$ORM_CPanel_THEME"
rm -f -- "$ORM_CPanel_LIVE/index.live.php"
rm -f -- "$ORM_WHM_CGI/addon_open_redis_manager.php" "$ORM_WHM_ICONS/orm-whm.png" \
    "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php" \
    "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php" \
    "$ORM_3RDPARTY/src/Orm/Security/SessionRequestGuard.php" \
    "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php" \
    "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php" \
    "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerClient.php" \
    "$ORM_3RDPARTY/src/Orm/Backend/BackendPolicyStore.php" \
    "$ORM_BROKER_BIN" \
    "$ORM_INSTANCE_LAUNCHER" \
    "$ORM_BROKER_LIB/AccountResolver.pm" "$ORM_BROKER_LIB/BackendPolicy.pm" \
    "$ORM_BROKER_LIB/Handler.pm" "$ORM_BROKER_LIB/InstanceManager.pm" \
    "$ORM_BROKER_LIB/PeerCredentials.pm" "$ORM_BROKER_LIB/Protocol.pm" \
    "$ORM_BROKER_LIB/Server.pm" "$ORM_BROKER_UNIT" "$ORM_INSTANCE_UNIT"
"$ORM_SYSTEMCTL" daemon-reload
restore_broker_on_exit=0
orm_remove_empty_owned_directories

if orm_registration_state; then "$ORM_UNREGISTER_APPCONFIG" open_redis_manager; fi
printf 'Open Redis Manager panel files and registrations removed. Redis/Valkey services, data, and configuration were left untouched.\n'
