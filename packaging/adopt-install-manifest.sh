#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/adopt-install-manifest.sh\nConverts a verified v1/v2 manifest to v3 when every installed ORM file exactly matches this checkout.\n'
    exit 0
fi
[[ $# -eq 0 ]] || orm_die 'unexpected arguments.'
orm_require_root_and_platform
orm_acquire_lifecycle_lock "$0" "$@"

orm_registration_state || orm_die 'WHM registration is missing or could not be verified.'
orm_appconfig_matches_package "$ORM_APPCONFIG" \
    || orm_die 'the installed WHM AppConfig differs from this checkout.'
orm_adopt_current_install_manifest "$ORM_INSTALL_MANIFEST" \
    || orm_die 'the installed manifest is unsupported or its version, files, ownership, or modes do not exactly match this checkout; no package files or services were changed.'
orm_validate_install_manifest "$ORM_INSTALL_MANIFEST" \
    || orm_die 'the adopted v3 manifest failed verification.'

printf 'The exact current ORM file set is now recorded in a v3 manifest. Package files, Redis/Valkey data, service state, registrations, and backend policy were not changed.\n'
