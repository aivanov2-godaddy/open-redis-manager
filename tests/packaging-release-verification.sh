#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'release verification tests must run as root.\n' >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/packaging/lib.sh"
source "$repo_root/packaging/release-lib.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-release-test.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
key_dir="$test_root/trusted-keys"
private_key="$test_root/test-private.pem"
metadata="$test_root/release.metadata"
signature="$test_root/release.sig"
mkdir -m 0700 "$key_dir"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key" >/dev/null 2>&1
openssl pkey -in "$private_key" -pubout -out "$key_dir/test-release.pem"
chmod 0600 "$private_key"
chmod 0644 "$key_dir/test-release.pem"
orm_release_safe_root_directory "$key_dir" \
    || { printf 'root-owned private key directory was rejected.\n' >&2; exit 1; }
unsafe_parent="$test_root/writable-parent"
mkdir -p "$unsafe_parent/child"
chmod 0777 "$unsafe_parent"
chmod 0700 "$unsafe_parent/child"
if orm_release_safe_root_directory "$unsafe_parent/child"; then
    printf 'writable non-sticky trust-key ancestor was accepted.\n' >&2
    exit 1
fi
chmod 01777 "$unsafe_parent"
orm_release_safe_root_directory "$unsafe_parent/child" \
    || { printf 'root-owned sticky temporary parent was rejected.\n' >&2; exit 1; }

future_day="$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')"
future_expiry="$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
past_day="$(date -u -d '-2 days' '+%Y-%m-%dT%H:%M:%SZ')"
past_expiry="$(date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')"
retired_target="$(awk -F'|' '$1 == "broker_provider_policy" { print $3 }' "$repo_root/packaging/release-install-map.txt")"

[[ "$(orm_semver_compare '1.2.3-alpha.2' '1.2.3-alpha.10')" == -1 \
    && "$(orm_semver_compare '1.2.3-rc.1' '1.2.3')" == -1 \
    && "$(orm_semver_compare '1.2.3+build.1' '1.2.3+build.2')" == 0 ]] \
    || { printf 'SemVer comparison does not follow prerelease/build ordering.\n' >&2; exit 1; }

write_artifact() {
    local version="$1" release_root="$test_root/orm-$1" path
    artifact="$test_root/orm-${version}.tar.gz"
    rm -rf -- "$release_root"
    mkdir -p "$release_root"
    printf '%s\n' "$version" >"$release_root/VERSION"
    while IFS= read -r path; do
        [[ "$path" == VERSION ]] && continue
        mkdir -p "$release_root/$(dirname -- "$path")"
        cp -- "$repo_root/$path" "$release_root/$path"
        chmod 0644 "$release_root/$path"
    done <"$repo_root/packaging/release-required-files.txt"
    while IFS= read -r path; do
        [[ -d "$path" && ! -L "$path" ]] && chmod 0755 "$path"
    done < <(find "$release_root" -type d -print)
    chmod 0644 "$release_root/VERSION"
    if [[ ! -s "$release_root/packaging/release-required-files.txt" ]]; then
        printf 'release required-file manifest was not copied.\n' >&2
        exit 1
    fi
    tar -czf "$artifact" -C "$test_root" "orm-${version}"
}

write_metadata() {
    local version="${1:-0.2.0}" minimum="${2:-0.1.0-dev}" maximum="${3:-0.1.0-dev}"
    local created="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}" expires="${5:-$future_expiry}" key_id="${6:-test-release}"
    local retired_target="${7:-}" state_migrations="${8:-none}" source_commit="${9:-0000000000000000000000000000000000000001}" install_map
    local size digest
    write_artifact "$version"
    if [[ -n "$retired_target" ]]; then
        install_map="$test_root/orm-$version/packaging/release-install-map.txt"
        awk -F'|' -v target="$retired_target" '$3 != target' "$install_map" >"$install_map.tmp"
        mv -- "$install_map.tmp" "$install_map"
        [[ "$(wc -l <"$install_map")" -eq "$(($(wc -l <"$repo_root/packaging/release-install-map.txt") - 1))" ]] \
            || { printf 'retirement fixture did not remove exactly one candidate target.\n' >&2; exit 1; }
        tar -czf "$artifact" -C "$test_root" "orm-${version}"
    fi
    size="$(stat -c '%s' -- "$artifact")"
    digest="$(sha256sum -- "$artifact" | awk '{print $1}')"
    {
        printf 'orm-release-metadata-v2\n'
        printf 'product|orm\nkey_id|%s\nversion|%s\nchannel|stable\nsource_commit|%s\nstate_migrations|%s\n' \
            "$key_id" "$version" "$source_commit" "$state_migrations"
        printf 'artifact|orm-%s.tar.gz\nartifact_size|%s\nartifact_sha256|%s\n' "$version" "$size" "$digest"
        printf 'min_from_version|%s\nmax_from_version|%s\ncreated_at|%s\nexpires_at|%s\n' "$minimum" "$maximum" "$created" "$expires"
    } >"$metadata"
    openssl dgst -sha256 -sign "$private_key" -out "$signature" "$metadata"
}

expect_invalid() {
    local description="$1"
    if orm_release_metadata_verify "$metadata" "$signature" "$artifact" "$key_dir" '0.1.0-dev' >/dev/null 2>&1; then
        printf 'release verification accepted %s.\n' "$description" >&2
        exit 1
    fi
}

write_metadata 0.2.0 0.1.0-dev 0.1.0-dev '' '' test-release "$retired_target"
[[ "$(orm_release_verify_bundle "$metadata" "$signature" "$artifact" "$key_dir" '0.1.0-dev')" == 0.2.0 ]] \
    || { printf 'valid signed release was rejected.\n' >&2; exit 1; }
staged_alias="$test_root/release.tar.gz"
cp -- "$artifact" "$staged_alias"
[[ "$(orm_release_verify_bundle "$metadata" "$signature" "$staged_alias" "$key_dir" '0.1.0-dev')" == 0.2.0 ]] \
    || { printf 'signed release was rejected under the fixed WHM staging filename.\n' >&2; exit 1; }
unapproved_alias="$test_root/upload.tar.gz"
cp -- "$artifact" "$unapproved_alias"
if orm_release_metadata_verify "$metadata" "$signature" "$unapproved_alias" "$key_dir" '0.1.0-dev' >/dev/null 2>&1; then
    printf 'signed release was accepted under an unapproved archive filename.\n' >&2
    exit 1
fi
write_metadata 0.2.0 0.1.0-dev 0.1.0-dev '' '' test-release '' 'provider-v4-to-v5'
expect_invalid 'a signed release declaring an unsupported state migration'
write_metadata 0.2.0 0.1.0-dev 0.1.0-dev '' '' test-release '' none 'abc'
expect_invalid 'a signed release with an invalid source commit'
write_metadata 0.2.0 0.1.0-dev 0.1.0-dev '' '' test-release "$retired_target"

target_root="$test_root/installed-targets"
installed_manifest="$test_root/installed-manifest"
mkdir -m 0700 "$target_root"
IFS='|' read -r first_key first_source first_target first_mode <"$repo_root/packaging/release-install-map.txt"
first_path="$target_root$first_target"
mkdir -p "$(dirname -- "$first_path")"
printf 'installed copy before update\n' >"$first_path"
chmod "$first_mode" "$first_path"
first_digest="$(sha256sum -- "$first_path" | awk '{print $1}')"
IFS='|' read -r second_key second_source second_target second_mode < <(sed -n '2p' "$repo_root/packaging/release-install-map.txt")
second_path="$target_root$second_target"
mkdir -p "$(dirname -- "$second_path")"
printf 'unmanaged file collision\n' >"$second_path"
chmod "$second_mode" "$second_path"
IFS='|' read -r third_key third_source third_target third_mode < <(sed -n '3p' "$repo_root/packaging/release-install-map.txt")
third_path="$target_root$third_target"
mkdir -p "$(dirname -- "$third_path")"
printf 'installed file before local edit\n' >"$third_path"
chmod "$third_mode" "$third_path"
third_digest="$(sha256sum -- "$third_path" | awk '{print $1}')"
retired_key='obsolete_module'
retired_path="$target_root$retired_target"
mkdir -p "$(dirname -- "$retired_path")"
printf 'previously managed file\n' >"$retired_path"
chmod 0644 "$retired_path"
retired_digest="$(sha256sum -- "$retired_path" | awk '{print $1}')"
{
    printf 'orm-install-manifest-v3\nversion|0.1.0-dev\n'
    printf '%s|%s|%s|%s\n' "$first_key" "$first_mode" "$first_digest" "$first_target"
    printf '%s|%s|%s|%s\n' "$third_key" "$third_mode" "$third_digest" "$third_target"
    printf '%s|%s|%s|%s\n' "$retired_key" '644' "$retired_digest" "$retired_target"
} >"$installed_manifest"
chmod 0600 "$installed_manifest"
printf 'operator-edited file\n' >"$third_path"
third_observed_digest="$(sha256sum -- "$third_path" | awk '{print $1}')"
adopt_key='application_discovery'
IFS='|' read -r adopt_key adopt_source adopt_target adopt_mode < <(awk -F'|' '$1 == "application_discovery" { print }' "$repo_root/packaging/release-install-map.txt")
adopt_path="$target_root$adopt_target"
mkdir -p "$(dirname -- "$adopt_path")"
cp -- "$test_root/orm-0.2.0/$adopt_source" "$adopt_path"
chmod "$adopt_mode" "$adopt_path"
target_snapshot() {
    {
        find "$target_root" -printf '%P|%y|%u|%g|%m|%s\n' | sort
        find "$target_root" -type f -print0 | sort -z | xargs -0 -r sha256sum
    }
}
before_preview="$(target_snapshot)"

preview="$(bash "$repo_root/packaging/preview-release.sh" \
    "$metadata" "$signature" "$artifact" "$key_dir" '0.1.0-dev' "$installed_manifest" "$target_root")" \
    || { printf 'valid signed release did not produce a preview.\n' >&2; exit 1; }
raw_inventory="$("$ORM_PERL" "$repo_root/packaging/inspect-release-archive.pl" "$artifact" '0.2.0' --json)"
computed_preview="$(printf '%s\n' "$raw_inventory" | "$ORM_PERL" \
    "$repo_root/packaging/compare-release-preview.pl" "$installed_manifest" '0.1.0-dev' "$metadata" "$target_root")" \
    || { printf 'raw target comparison could not be computed.\n' >&2; exit 1; }
printf '%s\n' "$computed_preview" | "$ORM_PERL" -MJSON::PP -e '
    local $/;
    my $preview = decode_json(<STDIN>);
    exit 1 if $preview->{verified} || $preview->{signatureVerified};
    exit 1 unless $preview->{attestationStatus} eq "unverified-by-comparator";
    exit 1 unless $preview->{targetComparison} eq "test-fixture-computed";
' || { printf 'the raw comparator incorrectly asserted release verification.\n' >&2; exit 1; }
expected_artifact_digest="$(sha256sum -- "$artifact" | awk '{print $1}')"
expected_artifact_size="$(stat -c '%s' -- "$artifact")"
expected_artifact="$(awk -F'|' '$1 == "artifact" { print $2 }' "$metadata")"
expected_channel="$(awk -F'|' '$1 == "channel" { print $2 }' "$metadata")"
expected_state_migrations="$(awk -F'|' '$1 == "state_migrations" { print $2 }' "$metadata")"
expected_source_commit="$(awk -F'|' '$1 == "source_commit" { print $2 }' "$metadata")"
expected_created_at="$(awk -F'|' '$1 == "created_at" { print $2 }' "$metadata")"
expected_expires_at="$(awk -F'|' '$1 == "expires_at" { print $2 }' "$metadata")"
expected_add="$(($(wc -l <"$repo_root/packaging/release-install-map.txt") - 5))"
after_preview="$(target_snapshot)"
[[ "$before_preview" == "$after_preview" && -f "$retired_path" ]] \
    || { printf 'release preview changed an installed fixture.\n' >&2; exit 1; }
printf '%s\n' "$preview" | "$ORM_PERL" -MJSON::PP -e '
    local $/;
    my ($expected_digest, $expected_size, $expected_channel, $expected_state_migrations, $expected_source_commit, $expected_artifact,
        $expected_created_at, $expected_expires_at, $expected_target, $expected_observed_digest, $expected_add) = @ARGV;
    my $preview = decode_json(<STDIN>);
    exit 1 unless $preview->{schema} eq "orm-update-preview-v2";
    exit 1 unless $preview->{installedVersion} eq "0.1.0-dev";
    exit 1 unless $preview->{candidateVersion} eq "0.2.0";
    exit 1 unless $preview->{verified} && !$preview->{mutationsApplied};
    exit 1 unless $preview->{targetComparison} eq "test-fixture";
    exit 1 unless $preview->{manifestSchema} == 3;
    exit 1 unless $preview->{signatureVerified} && $preview->{signatureAlgorithm} eq "RSA-SHA256";
    exit 1 unless $preview->{release}{keyId} eq "test-release";
    exit 1 unless $preview->{release}{channel} eq $expected_channel;
    exit 1 unless $preview->{release}{stateMigrations} eq $expected_state_migrations;
    exit 1 unless $preview->{release}{sourceCommit} eq $expected_source_commit;
    exit 1 unless $preview->{release}{artifact} eq $expected_artifact;
    exit 1 unless $preview->{release}{createdAt} eq $expected_created_at;
    exit 1 unless $preview->{release}{expiresAt} eq $expected_expires_at;
    exit 1 unless $preview->{release}{artifactSha256} eq $expected_digest;
    exit 1 unless $preview->{release}{artifactSize} == $expected_size;
    exit 1 unless $preview->{release}{minimumFromVersion} eq "0.1.0-dev";
    exit 1 unless $preview->{release}{maximumFromVersion} eq "0.1.0-dev";
    exit 1 unless ref($preview->{migrationActions}) eq "ARRAY" && !$preview->{migrationPlanAvailable};
    exit 1 unless $preview->{summary}{replace} == 1 && $preview->{summary}{add} == $expected_add;
    exit 1 unless $preview->{summary}{adopt} == 1;
    exit 1 unless $preview->{summary}{conflict} == 2 && $preview->{summary}{retire} == 1;
    exit 1 unless grep { $_->{key} eq "cpanel_entry" && $_->{action} eq "replace" } @{$preview->{fileActions}};
    exit 1 unless grep { $_->{key} eq "application_discovery" && $_->{action} eq "adopt" && $_->{requiresReview} } @{$preview->{fileActions}};
    exit 1 unless grep { $_->{key} eq "whm_cgi" && $_->{action} eq "conflict" && $_->{requiresReview} } @{$preview->{fileActions}};
    exit 1 unless grep {
        $_->{key} eq "whm_icon"
            && $_->{action} eq "conflict"
            && $_->{conflictReason} eq "digest_changed"
            && $_->{target} eq $expected_target
            && $_->{observedSha256} eq $expected_observed_digest
    } @{$preview->{fileActions}};
    exit 1 unless grep { $_->{key} eq "obsolete_module" && $_->{action} eq "retire" && $_->{requiresReview} } @{$preview->{fileActions}};
' "$expected_artifact_digest" "$expected_artifact_size" "$expected_channel" "$expected_state_migrations" "$expected_source_commit" "$expected_artifact" \
    "$expected_created_at" "$expected_expires_at" "$third_target" "$third_observed_digest" "$expected_add" \
    || { printf 'release preview JSON did not report correct read-only target actions.\n' >&2; exit 1; }

assert_adoption_is_conflict() {
    local case_name="$1" result
    result="$(printf '%s\n' "$raw_inventory" | "$ORM_PERL" \
        "$repo_root/packaging/compare-release-preview.pl" "$installed_manifest" '0.1.0-dev' "$metadata" "$target_root")" \
        || { printf 'candidate preview failed during %s adoption check.\n' "$case_name" >&2; exit 1; }
    printf '%s\n' "$result" | "$ORM_PERL" -MJSON::PP -e '
        local $/;
        my $preview = decode_json(<STDIN>);
        exit 1 unless grep { $_->{key} eq "application_discovery" && $_->{action} eq "conflict" } @{$preview->{fileActions}};
    ' || { printf 'preview did not reject unsafe adoption case: %s.\n' "$case_name" >&2; exit 1; }
}

adopt_backup="$test_root/application-discovery.exact"
cp -a -- "$adopt_path" "$adopt_backup"
perl -pe 's/\r?\n/\r\n/g' "$adopt_backup" >"$adopt_path"
chmod "$adopt_mode" "$adopt_path"
crlf_observed_digest="$(sha256sum -- "$adopt_path" | awk '{print $1}')"
crlf_preview="$(printf '%s\n' "$raw_inventory" | "$ORM_PERL" \
    "$repo_root/packaging/compare-release-preview.pl" "$installed_manifest" '0.1.0-dev' "$metadata" "$target_root")"
printf '%s\n' "$crlf_preview" | "$ORM_PERL" -MJSON::PP -e '
    local $/;
    my $preview = decode_json(<STDIN>);
    exit 1 unless $preview->{summary}{normalize} == 1;
    exit 1 unless grep { $_->{key} eq "application_discovery" && $_->{action} eq "normalize"
        && $_->{requiresReview} && $_->{observedSha256} eq $ARGV[0] } @{$preview->{fileActions}};
' "$crlf_observed_digest" || { printf 'preview did not classify the exact CRLF-only candidate as reviewed normalization.\n' >&2; exit 1; }
cp -- "$adopt_backup" "$adopt_path"
chmod "$adopt_mode" "$adopt_path"
printf 'changed content\n' >"$adopt_path"
chmod "$adopt_mode" "$adopt_path"
assert_adoption_is_conflict 'digest mismatch'
cp -- "$adopt_backup" "$adopt_path"
chmod 0600 "$adopt_path"
assert_adoption_is_conflict 'mode mismatch'
cp -- "$adopt_backup" "$adopt_path"
chmod "$adopt_mode" "$adopt_path"
chown 1:1 "$adopt_path"
assert_adoption_is_conflict 'owner mismatch'
chown root:root "$adopt_path"
mv -- "$adopt_path" "$adopt_path.saved"
ln -s -- "$adopt_path.saved" "$adopt_path"
assert_adoption_is_conflict 'symlink target'
rm -- "$adopt_path"
mv -- "$adopt_path.saved" "$adopt_path"
chmod "$adopt_mode" "$adopt_path"
chown root:root "$adopt_path"

for legacy_schema in v1 v2; do
    legacy_manifest="$test_root/legacy-$legacy_schema-manifest"
    if [[ "$legacy_schema" == v1 ]]; then
        printf 'orm-install-manifest-v1\n%s|%s|%s\n' "$first_key" "$first_mode" "$first_digest" >"$legacy_manifest"
    else
        printf 'orm-install-manifest-v2\nversion|0.1.0-dev\n%s|%s|%s\n' "$first_key" "$first_mode" "$first_digest" >"$legacy_manifest"
    fi
    chmod 0600 "$legacy_manifest"
    if bash "$repo_root/packaging/preview-release.sh" \
        "$metadata" "$signature" "$artifact" "$key_dir" '0.1.0-dev' "$legacy_manifest" "$target_root" >/dev/null 2>&1; then
        printf 'live update preview accepted a %s manifest without target paths.\n' "$legacy_schema" >&2
        exit 1
    fi
done

if (cd "$test_root" && orm_release_metadata_verify release.metadata release.sig "$artifact" "$key_dir" '0.1.0-dev' >/dev/null 2>&1); then
    printf 'relative release paths were accepted.\n' >&2
    exit 1
fi

printf 'tampered\n' >>"$artifact"
expect_invalid 'an artifact whose digest changed'

write_metadata
sed -i 's/^version|0\.2\.0$/version|0.2.1/' "$metadata"
expect_invalid 'metadata modified after signing'

write_metadata 0.2.0 0.1.0-dev 0.1.0-dev "$past_day" "$past_expiry"
expect_invalid 'expired metadata'

write_metadata 0.2.0 0.2.0 0.3.0
expect_invalid 'an installed version outside the signed compatibility range'

write_metadata 0.1.0-dev
expect_invalid 'a non-upgrade or equal-version release'

write_metadata 0.2.0 0.1.0-dev 0.1.0-dev "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" "$future_expiry"
expect_invalid 'metadata issued too far in the future'

write_metadata 0.2.0 0.1.0-dev 0.1.0-dev "$future_day" "$future_expiry" unknown-key
expect_invalid 'a key id without a pinned public key'

write_metadata
sed -i 's/^key_id|test-release$/key_id|test-release\nkey_id|test-release/' "$metadata"
expect_invalid 'duplicate metadata fields'

printf 'Signed release metadata and artifact verification checks passed.\n'
