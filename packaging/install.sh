#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/install.sh\nInstalls the ORM cPanel/WHM entries and account-scoped Redis/Valkey lifecycle adapter.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
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
            rm -f -- "$ORM_WHM_CGI/addon_open_redis_manager.php" "$ORM_WHM_ICONS/orm-whm.png" \
                "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php" \
                "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php" \
                "$ORM_3RDPARTY/src/Orm/Security/SessionRequestGuard.php" \
                "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php" \
                "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php" \
                "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerClient.php" \
                "$ORM_3RDPARTY/src/Orm/Cpanel/ConnectionDetails.php" \
                "$ORM_3RDPARTY/src/Orm/Backend/BackendPolicyStore.php" \
                "$ORM_BROKER_BIN" \
                "$ORM_INSTANCE_LAUNCHER" \
                "$ORM_BROKER_LIB/AccountResolver.pm" "$ORM_BROKER_LIB/BackendPolicy.pm" "$ORM_BROKER_LIB/Handler.pm" \
                "$ORM_BROKER_LIB/InstanceManager.pm" \
                "$ORM_BROKER_LIB/PeerCredentials.pm" "$ORM_BROKER_LIB/Protocol.pm" \
                "$ORM_BROKER_LIB/Server.pm" "$ORM_BROKER_UNIT" "$ORM_INSTANCE_UNIT" \
                "$ORM_CPanel_LIVE/index.live.php"
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
mkdir -p -- "$ORM_CPanel_LIVE" "$ORM_WHM_CGI" "$ORM_WHM_ICONS" \
    "$ORM_3RDPARTY/src/Orm/Backend" "$ORM_3RDPARTY/src/Orm/Security" \
    "$ORM_3RDPARTY/src/Orm/Cpanel" "$ORM_3RDPARTY/bin" "$ORM_BROKER_LIB"
installed_files=1
orm_prepare_instance_directories
install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/files/orm/index.live.php" "$ORM_CPanel_LIVE/index.live.php"
install -m 0644 "$ORM_PACKAGE_ROOT/whm/cgi/addon_open_redis_manager.php" "$ORM_WHM_CGI/addon_open_redis_manager.php"
install -m 0644 "$ORM_PACKAGE_ROOT/whm/icons/orm-whm.png" "$ORM_WHM_ICONS/orm-whm.png"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Backend/BackendDiscovery.php" "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Security/WhmAcl.php" "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Security/SessionRequestGuard.php" "$ORM_3RDPARTY/src/Orm/Security/SessionRequestGuard.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Cpanel/AuthenticatedAccountContext.php" "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerIdentityVerifier.php" "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerClient.php" "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerClient.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Cpanel/ConnectionDetails.php" "$ORM_3RDPARTY/src/Orm/Cpanel/ConnectionDetails.php"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Backend/BackendPolicyStore.php" "$ORM_3RDPARTY/src/Orm/Backend/BackendPolicyStore.php"
install -m 0755 "$ORM_REPO_ROOT/bin/orm-broker.pl" "$ORM_BROKER_BIN"
install -m 0755 "$ORM_REPO_ROOT/bin/orm-instance-launcher.pl" "$ORM_INSTANCE_LAUNCHER"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Broker/AccountResolver.pm" "$ORM_BROKER_LIB/AccountResolver.pm"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Broker/BackendPolicy.pm" "$ORM_BROKER_LIB/BackendPolicy.pm"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Broker/Handler.pm" "$ORM_BROKER_LIB/Handler.pm"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Broker/InstanceManager.pm" "$ORM_BROKER_LIB/InstanceManager.pm"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Broker/PeerCredentials.pm" "$ORM_BROKER_LIB/PeerCredentials.pm"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Broker/Protocol.pm" "$ORM_BROKER_LIB/Protocol.pm"
install -m 0644 "$ORM_REPO_ROOT/src/Orm/Broker/Server.pm" "$ORM_BROKER_LIB/Server.pm"
install -m 0644 "$ORM_PACKAGE_ROOT/systemd/orm-broker.service" "$ORM_BROKER_UNIT"
install -m 0644 "$ORM_PACKAGE_ROOT/systemd/orm-instance@.service" "$ORM_INSTANCE_UNIT"
"$ORM_SYSTEMCTL" daemon-reload
broker_started=1
"$ORM_SYSTEMCTL" enable --now orm-broker.service
registered_whm=1
"$ORM_REGISTER_APPCONFIG" "$ORM_PACKAGE_ROOT/whm/open_redis_manager.conf"
printf 'Open Redis Manager installed. WHM backend selection and account-scoped Redis/Valkey lifecycle controls are available; configuration, credentials, monitoring, and backups remain under development.\n'
