#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
source "$ORM_PACKAGE_ROOT/release-lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/preview-release.sh METADATA SIGNATURE ARCHIVE TRUSTED_KEY_DIR INSTALLED_VERSION [INSTALL_MANIFEST [TEST_TARGET_ROOT]]\n'
    printf 'Verifies a signed release and prints a read-only installed-file change preview as JSON.\n'
    exit 0
fi
[[ $# -ge 5 && $# -le 7 ]] || orm_die 'expected metadata, signature, archive, trusted key directory, installed version, and optional manifest/test fixture root.'
[[ "$(id -u)" -eq 0 ]] || orm_die 'run release preview as root.'

metadata="$1"
signature="$2"
archive="$3"
trusted_key_dir="$4"
installed_version="$5"
install_manifest="${6:-$ORM_INSTALL_MANIFEST}"
candidate_version="$(orm_release_metadata_verify \
    "$metadata" "$signature" "$archive" "$trusted_key_dir" "$installed_version")" \
    || orm_die 'signed release bundle verification failed; no preview was produced.'
inventory="$("$ORM_PERL" "$ORM_PACKAGE_ROOT/inspect-release-archive.pl" \
    "$archive" "$candidate_version" --json)" \
    || orm_die 'could not construct the verified release inventory.'
if [[ $# -eq 7 ]]; then
    comparison="$(printf '%s\n' "$inventory" | "$ORM_PERL" "$ORM_PACKAGE_ROOT/compare-release-preview.pl" \
        "$install_manifest" "$installed_version" "$metadata" "$7")" \
        || orm_die 'could not compare the verified release against installed files.'
    printf '%s\n' "$comparison" | "$ORM_PERL" -MJSON::PP -e '
        local $/;
        my $preview = decode_json(<STDIN>);
        $preview->{verified} = JSON::PP::true;
        $preview->{signatureVerified} = JSON::PP::true;
        $preview->{signatureAlgorithm} = "RSA-SHA256";
        $preview->{attestationStatus} = "verified";
        $preview->{targetComparison} = "test-fixture";
        print JSON::PP->new->canonical->encode($preview), "\n";
    '
else
    comparison="$(printf '%s\n' "$inventory" | "$ORM_PERL" "$ORM_PACKAGE_ROOT/compare-release-preview.pl" \
        "$install_manifest" "$installed_version" "$metadata")" \
        || orm_die 'could not compare the verified release against installed files.'
    printf '%s\n' "$comparison" | "$ORM_PERL" -MJSON::PP -e '
        local $/;
        my $preview = decode_json(<STDIN>);
        $preview->{verified} = JSON::PP::true;
        $preview->{signatureVerified} = JSON::PP::true;
        $preview->{signatureAlgorithm} = "RSA-SHA256";
        $preview->{attestationStatus} = "verified";
        $preview->{targetComparison} = "verified";
        print JSON::PP->new->canonical->encode($preview), "\n";
    '
fi
