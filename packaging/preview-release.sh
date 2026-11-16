#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
source "$ORM_PACKAGE_ROOT/release-lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/preview-release.sh METADATA SIGNATURE ARCHIVE TRUSTED_KEY_DIR INSTALLED_VERSION\n'
    printf 'Verifies a signed release bundle and prints a read-only JSON inventory.\n'
    exit 0
fi
[[ $# -eq 5 ]] || orm_die 'expected metadata, signature, archive, trusted key directory, and installed version.'
[[ "$(id -u)" -eq 0 ]] || orm_die 'run release preview as root.'

metadata="$1"
signature="$2"
archive="$3"
trusted_key_dir="$4"
installed_version="$5"
candidate_version="$(orm_release_metadata_verify \
    "$metadata" "$signature" "$archive" "$trusted_key_dir" "$installed_version")" \
    || orm_die 'signed release bundle verification failed; no preview was produced.'
inventory="$("$ORM_PERL" "$ORM_PACKAGE_ROOT/inspect-release-archive.pl" \
    "$archive" "$candidate_version" --json)" \
    || orm_die 'could not construct the verified release inventory.'

printf '{"schema":"orm-update-preview-v1","installedVersion":"%s","candidateVersion":"%s","verified":true,"mutationsApplied":false,"migrationActions":[],"archiveInventory":%s}\n' \
    "$installed_version" "$candidate_version" "$inventory"
