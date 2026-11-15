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
ORM_APPCONFIG=/var/cpanel/apps/open_redis_manager.conf
ORM_PERL=/usr/bin/perl
ORM_SYSTEMCTL=/usr/bin/systemctl
ORM_BROKER_BIN="$ORM_3RDPARTY/bin/orm-broker.pl"
ORM_BROKER_LIB="$ORM_3RDPARTY/lib/Orm/Broker"
ORM_BROKER_UNIT=/etc/systemd/system/orm-broker.service

orm_die() { printf 'ORM installer: %s\n' "$*" >&2; exit 1; }

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
    mkdir -p "$stage/orm"
    install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/install.json" "$stage/orm/install.json"
    install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-group.svg" "$stage/orm/orm-group.svg"
    install -m 0644 "$ORM_PACKAGE_ROOT/cpanel/icons/orm-feature.svg" "$stage/orm/orm-feature.svg"
    tar -czf "$destination" -C "$stage/orm" install.json orm-group.svg orm-feature.svg
    rm -rf -- "$stage"
}

orm_registration_state() {
    local result
    result="$("$ORM_IS_REGISTERED" whostmgr open_redis_manager 2>/dev/null || true)"
    [[ "$result" == 1 ]]
}

orm_install_paths_are_clear() {
    local path unit_state
    for path in \
        "$ORM_CPanel_LIVE/index.live.php" \
        "$ORM_WHM_CGI/addon_open_redis_manager.php" \
        "$ORM_WHM_ICONS/orm-whm.png" \
        "$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php" \
        "$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php" \
        "$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php" \
        "$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php" \
        "$ORM_BROKER_BIN" \
        "$ORM_BROKER_LIB/AccountResolver.pm" \
        "$ORM_BROKER_LIB/Handler.pm" \
        "$ORM_BROKER_LIB/PeerCredentials.pm" \
        "$ORM_BROKER_LIB/Protocol.pm" \
        "$ORM_BROKER_LIB/Server.pm" \
        "$ORM_BROKER_UNIT" \
        "$ORM_APPCONFIG"; do
        [[ ! -e "$path" && ! -L "$path" ]] || orm_die "refusing to overwrite existing path: $path"
    done
    unit_state="$("$ORM_SYSTEMCTL" list-unit-files --no-legend --no-pager orm-broker.service 2>/dev/null || true)"
    [[ -z "$unit_state" ]] || orm_die 'an orm-broker.service unit already exists; refusing to replace it.'
    ! orm_registration_state || orm_die 'the WHM AppConfig application is already registered.'
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
        "$ORM_3RDPARTY/src/Orm" \
        "$ORM_3RDPARTY/src" \
        "$ORM_3RDPARTY" \
        "$ORM_CPanel_LIVE"; do
        rmdir -- "$path" 2>/dev/null || true
    done
}

orm_verify_installed_files() {
    local source target
    while IFS='|' read -r source target; do
        [[ ! -e "$target" ]] && continue
        [[ -f "$target" && -f "$source" ]] || orm_die "refusing to remove an unexpected ORM path: $target"
        cmp -s -- "$source" "$target" || orm_die "installed file differs from this package; refusing removal: $target"
    done <<EOF
$ORM_PACKAGE_ROOT/cpanel/files/orm/index.live.php|$ORM_CPanel_LIVE/index.live.php
$ORM_PACKAGE_ROOT/whm/cgi/addon_open_redis_manager.php|$ORM_WHM_CGI/addon_open_redis_manager.php
$ORM_PACKAGE_ROOT/whm/icons/orm-whm.png|$ORM_WHM_ICONS/orm-whm.png
$ORM_REPO_ROOT/src/Orm/Backend/BackendDiscovery.php|$ORM_3RDPARTY/src/Orm/Backend/BackendDiscovery.php
$ORM_REPO_ROOT/src/Orm/Security/WhmAcl.php|$ORM_3RDPARTY/src/Orm/Security/WhmAcl.php
$ORM_REPO_ROOT/src/Orm/Cpanel/AuthenticatedAccountContext.php|$ORM_3RDPARTY/src/Orm/Cpanel/AuthenticatedAccountContext.php
$ORM_REPO_ROOT/src/Orm/Cpanel/BrokerIdentityVerifier.php|$ORM_3RDPARTY/src/Orm/Cpanel/BrokerIdentityVerifier.php
$ORM_REPO_ROOT/bin/orm-broker.pl|$ORM_BROKER_BIN
$ORM_REPO_ROOT/src/Orm/Broker/AccountResolver.pm|$ORM_BROKER_LIB/AccountResolver.pm
$ORM_REPO_ROOT/src/Orm/Broker/Handler.pm|$ORM_BROKER_LIB/Handler.pm
$ORM_REPO_ROOT/src/Orm/Broker/PeerCredentials.pm|$ORM_BROKER_LIB/PeerCredentials.pm
$ORM_REPO_ROOT/src/Orm/Broker/Protocol.pm|$ORM_BROKER_LIB/Protocol.pm
$ORM_REPO_ROOT/src/Orm/Broker/Server.pm|$ORM_BROKER_LIB/Server.pm
$ORM_PACKAGE_ROOT/systemd/orm-broker.service|$ORM_BROKER_UNIT
EOF
}
