#!/usr/bin/env bash
set -Eeuo pipefail

ORM_RELEASE_METADATA_MAX_BYTES=8192
ORM_RELEASE_ARTIFACT_MAX_BYTES=134217728
ORM_RELEASE_METADATA_MAX_AGE_SECONDS=7776000
ORM_RELEASE_CLOCK_SKEW_SECONDS=300

orm_release_crlf_normalized_sha256() {
    local path="${1:-}"
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || return 1
    "$ORM_PERL" -MDigest::SHA=sha256_hex -0777 -e '
        my $path = shift;
        open my $handle, "<:raw", $path or exit 2;
        local $/;
        my $bytes = <$handle>;
        close $handle or exit 2;
        exit 1 if !defined($bytes) || $bytes !~ /\r\n/ || $bytes =~ /\x00/ || $bytes =~ /\r(?!\n)/;
        $bytes =~ s/\r\n/\n/g;
        print sha256_hex($bytes);
    ' -- "$path"
}

orm_release_safe_root_directory() {
    local directory="${1:-}" owner mode rest component
    local -a components=()
    [[ "$directory" == /* && "$directory" != *//* ]] || return 1
    rest="${directory#/}"
    IFS='/' read -r -a components <<<"$rest"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
    done
    while :; do
        [[ -d "$directory" && ! -L "$directory" ]] || return 1
        owner="$(stat -c '%u' -- "$directory")" || return 1
        mode="$(stat -c '%a' -- "$directory")" || return 1
        [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        if (( (8#$mode & 0022) != 0 )); then
            (( (8#$mode & 01000) != 0 )) || return 1
        fi
        [[ "$directory" == / ]] && break
        directory="$(dirname -- "$directory")"
    done
}

orm_semver_compare() {
    local left="${1:-}" right="${2:-}" result
    orm_valid_version "$left" && orm_valid_version "$right" || return 2
    result="$("$ORM_PERL" - "$left" "$right" <<'PERL'
use strict;
use warnings;

sub parse_version {
    my ($value) = @_;
    $value =~ s/\+[^+]*\z//;
    my ($core, $pre) = split /-/, $value, 2;
    return ([split /\./, $core], defined($pre) ? [split /\./, $pre, -1] : undef);
}

sub compare_numeric {
    my ($left, $right) = @_;
    return length($left) <=> length($right) || $left cmp $right;
}

my ($left_core, $left_pre) = parse_version(shift);
my ($right_core, $right_pre) = parse_version(shift);
for my $index (0 .. 2) {
    my $comparison = compare_numeric($left_core->[$index], $right_core->[$index]);
    if ($comparison) { print $comparison < 0 ? "-1\n" : "1\n"; exit 0; }
}
if (!defined($left_pre) && !defined($right_pre)) { print "0\n"; exit 0; }
if (!defined($left_pre)) { print "1\n"; exit 0; }
if (!defined($right_pre)) { print "-1\n"; exit 0; }
for my $index (0 .. ($#$left_pre > $#$right_pre ? $#$left_pre : $#$right_pre)) {
    if ($index > $#$left_pre) { print "-1\n"; exit 0; }
    if ($index > $#$right_pre) { print "1\n"; exit 0; }
    my ($left_id, $right_id) = ($left_pre->[$index], $right_pre->[$index]);
    my ($left_numeric, $right_numeric) = ($left_id =~ /\A[0-9]+\z/, $right_id =~ /\A[0-9]+\z/);
    my $comparison = $left_numeric && $right_numeric
        ? compare_numeric($left_id, $right_id)
        : $left_numeric ? -1
        : $right_numeric ? 1
        : $left_id cmp $right_id;
    if ($comparison) { print $comparison < 0 ? "-1\n" : "1\n"; exit 0; }
}
print "0\n";
PERL
)" || return 2
    [[ "$result" == -1 || "$result" == 0 || "$result" == 1 ]] || return 2
    printf '%s\n' "$result"
}

orm_release_metadata_verify() {
    [[ $# -eq 5 ]] || return 2
    local metadata="$1" signature="$2" artifact="$3" trusted_key_dir="$4" installed_version="$5"
    local metadata_size signature_size artifact_size actual_digest archive_basename line key value extra index input_owner input_mode parent parent_owner parent_mode
    local expected_key product key_id version channel source_commit state_migrations artifact_name expected_size expected_digest
    local minimum_version maximum_version created_at expires_at key_path key_owner key_mode key_bits
    local created_epoch expires_epoch current_epoch compare_result
    local -a lines=()
    local -A values=()
    local -a expected_keys=(product key_id version channel source_commit state_migrations artifact artifact_size artifact_sha256 min_from_version max_from_version created_at expires_at)

    for line in "$metadata" "$signature" "$artifact"; do
        [[ "$line" == /* && "$line" != *//* ]] || return 1
        [[ -f "$line" && ! -L "$line" ]] || return 1
        input_owner="$(stat -c '%u' -- "$line")" || return 1
        input_mode="$(stat -c '%a' -- "$line")" || return 1
        parent="$(dirname -- "$line")"
        orm_release_safe_root_directory "$parent" || return 1
        parent_owner="$(stat -c '%u' -- "$parent")" || return 1
        parent_mode="$(stat -c '%a' -- "$parent")" || return 1
        [[ "$input_owner" == 0 && "$input_mode" =~ ^[0-7]{3,4}$ \
            && "$parent_owner" == 0 && "$parent_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$input_mode & 0022) == 0 && (8#$parent_mode & 0022) == 0 )) || return 1
    done
    [[ "$trusted_key_dir" == /* && "$trusted_key_dir" != *//* ]] || return 1
    orm_release_safe_root_directory "$trusted_key_dir" || return 1
    [[ -d "$trusted_key_dir" && ! -L "$trusted_key_dir" ]] || return 1
    key_owner="$(stat -c '%u' -- "$trusted_key_dir")" || return 1
    key_mode="$(stat -c '%a' -- "$trusted_key_dir")" || return 1
    [[ "$key_owner" == 0 && "$key_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$key_mode & 0022) == 0 )) || return 1
    [[ -n "$installed_version" ]] && orm_valid_version "$installed_version" || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    command -v stat >/dev/null 2>&1 || return 1
    command -v date >/dev/null 2>&1 || return 1

    metadata_size="$(stat -c '%s' -- "$metadata")" || return 1
    signature_size="$(stat -c '%s' -- "$signature")" || return 1
    artifact_size="$(stat -c '%s' -- "$artifact")" || return 1
    [[ "$metadata_size" =~ ^[0-9]+$ && "$metadata_size" -le "$ORM_RELEASE_METADATA_MAX_BYTES" ]] || return 1
    [[ "$signature_size" =~ ^[0-9]+$ && "$signature_size" -gt 0 && "$signature_size" -le 16384 ]] || return 1
    [[ "$artifact_size" =~ ^[1-9][0-9]{0,8}$ && "$artifact_size" -le "$ORM_RELEASE_ARTIFACT_MAX_BYTES" ]] || return 1
    "$ORM_PERL" -0777 -ne 'exit($_ =~ /\A[\x20-\x7E]+\n(?:[\x20-\x7E]+\n)*\z/ ? 0 : 1)' "$metadata" || return 1

    mapfile -t lines <"$metadata" || return 1
    [[ "${#lines[@]}" -eq 14 && "${lines[0]}" == orm-release-metadata-v2 ]] || return 1
    for index in "${!expected_keys[@]}"; do
        line="${lines[$((index + 1))]}"
        IFS='|' read -r key value extra <<<"$line"
        expected_key="${expected_keys[$index]}"
        [[ "$key" == "$expected_key" && -n "$value" && -z "${extra:-}" ]] || return 1
        values[$key]="$value"
    done

    product="${values[product]}"
    key_id="${values[key_id]}"
    version="${values[version]}"
    channel="${values[channel]}"
    source_commit="${values[source_commit]}"
    state_migrations="${values[state_migrations]}"
    artifact_name="${values[artifact]}"
    expected_size="${values[artifact_size]}"
    expected_digest="${values[artifact_sha256]}"
    minimum_version="${values[min_from_version]}"
    maximum_version="${values[max_from_version]}"
    created_at="${values[created_at]}"
    expires_at="${values[expires_at]}"

    [[ "$product" == orm ]] || return 1
    [[ "$key_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || return 1
    orm_valid_version "$version" && orm_valid_version "$minimum_version" && orm_valid_version "$maximum_version" || return 1
    [[ "$channel" == stable || "$channel" == preview ]] || return 1
    [[ "$source_commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || return 1
    [[ "$state_migrations" == none ]] || return 1
    archive_basename="$(basename -- "$artifact")"
    [[ "$artifact_name" == "orm-${version}.tar.gz" ]] || return 1
    [[ "$archive_basename" == "$artifact_name" || "$archive_basename" == release.tar.gz ]] || return 1
    [[ "$expected_size" =~ ^[1-9][0-9]{0,8}$ && "$expected_size" == "$artifact_size" ]] || return 1
    [[ "$expected_digest" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
        && "$expires_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1

    key_path="$trusted_key_dir/${key_id}.pem"
    [[ "$key_path" == /* && "$key_path" != *//* ]] || return 1
    [[ -f "$key_path" && ! -L "$key_path" ]] || return 1
    key_owner="$(stat -c '%u' -- "$key_path")" || return 1
    key_mode="$(stat -c '%a' -- "$key_path")" || return 1
    [[ "$key_owner" == 0 && "$key_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$key_mode & 0022) == 0 )) || return 1
    key_bits="$(openssl rsa -pubin -in "$key_path" -text -noout 2>/dev/null | sed -nE '1s/.*\(([0-9]+) bit\).*/\1/p')" || return 1
    [[ "$key_bits" =~ ^[0-9]+$ ]] && (( key_bits >= 3072 )) || return 1
    openssl dgst -sha256 -verify "$key_path" -signature "$signature" "$metadata" >/dev/null 2>&1 || return 1

    created_epoch="$(date -u -d "$created_at" '+%s' 2>/dev/null)" || return 1
    expires_epoch="$(date -u -d "$expires_at" '+%s' 2>/dev/null)" || return 1
    current_epoch="$(date -u '+%s')" || return 1
    [[ "$(date -u -d "@$created_epoch" '+%Y-%m-%dT%H:%M:%SZ')" == "$created_at" \
        && "$(date -u -d "@$expires_epoch" '+%Y-%m-%dT%H:%M:%SZ')" == "$expires_at" ]] || return 1
    (( created_epoch <= current_epoch + ORM_RELEASE_CLOCK_SKEW_SECONDS )) || return 1
    (( expires_epoch > current_epoch && expires_epoch > created_epoch \
        && expires_epoch - created_epoch <= ORM_RELEASE_METADATA_MAX_AGE_SECONDS )) || return 1

    compare_result="$(orm_semver_compare "$minimum_version" "$maximum_version")" || return 1
    [[ "$compare_result" != 1 ]] || return 1
    compare_result="$(orm_semver_compare "$minimum_version" "$installed_version")" || return 1
    [[ "$compare_result" != 1 ]] || return 1
    compare_result="$(orm_semver_compare "$installed_version" "$maximum_version")" || return 1
    [[ "$compare_result" != 1 ]] || return 1
    compare_result="$(orm_semver_compare "$version" "$installed_version")" || return 1
    [[ "$compare_result" == 1 ]] || return 1

    actual_digest="$(sha256sum -- "$artifact" | awk '{print $1}')" || return 1
    [[ "$actual_digest" == "$expected_digest" ]] || return 1
    printf '%s\n' "$version"
}

orm_release_verify_bundle() {
    [[ $# -eq 5 ]] || return 2
    local artifact="$3" version
    version="$(orm_release_metadata_verify "$@")" || return 1
    "$ORM_PERL" "$ORM_PACKAGE_ROOT/inspect-release-archive.pl" "$artifact" "$version" >/dev/null || return 1
    printf '%s\n' "$version"
}
