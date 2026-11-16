#!/usr/bin/env bash
set -Eeuo pipefail

package_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$package_root/.." && pwd -P)"
source "$package_root/lib.sh"
source "$package_root/release-lib.sh"

if [[ "${1:-}" == --help ]]; then
    cat <<'HELP'
Usage: bash packaging/build-release.sh VERSION CHANNEL KEY_ID MIN_FROM_VERSION MAX_FROM_VERSION PRIVATE_KEY OUTPUT_DIRECTORY [VALID_DAYS]

Builds and signs one release from a clean Git checkout. The private RSA key must
be an absolute path outside the repository; it is never copied to the output.
The output directory must already exist outside the repository and must not be group/world writable.
The command creates a new orm-VERSION directory and refuses to overwrite it.
HELP
    exit 0
fi
[[ $# -ge 7 && $# -le 8 ]] || orm_die 'expected version, channel, key ID, compatibility range, private key, output directory, and optional validity days.'

version="$1"
channel="$2"
key_id="$3"
minimum_version="$4"
maximum_version="$5"
private_key="$6"
output_directory="$7"
valid_days="${8:-30}"

orm_valid_version "$version" && orm_valid_version "$minimum_version" && orm_valid_version "$maximum_version" \
    || orm_die 'release version or compatibility range is invalid.'
[[ "$channel" == stable || "$channel" == preview ]] || orm_die 'channel must be stable or preview.'
[[ "$channel" != stable || "$version" != *-* ]] || orm_die 'stable releases cannot use a prerelease version.'
[[ "$key_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || orm_die 'key ID is invalid.'
[[ "$valid_days" =~ ^([1-9]|[1-8][0-9]|90)$ ]] || orm_die 'validity must be between 1 and 90 days.'

range_order="$(orm_semver_compare "$minimum_version" "$maximum_version")" \
    || orm_die 'could not compare the compatibility range.'
[[ "$range_order" != 1 ]] || orm_die 'minimum compatible version is newer than the maximum.'
candidate_order="$(orm_semver_compare "$version" "$maximum_version")" \
    || orm_die 'could not compare the release and compatibility versions.'
[[ "$candidate_order" == 1 ]] || orm_die 'release version must be newer than the maximum compatible installed version.'

git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || orm_die 'release source must be a Git checkout.'
[[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] \
    || orm_die 'release source root is not the Git checkout root.'
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] \
    || orm_die 'release source checkout must be clean; commit reviewed files before building.'
[[ -f "$repo_root/VERSION" && ! -L "$repo_root/VERSION" ]] || orm_die 'release VERSION file is missing or unsafe.'
source_version="$(<"$repo_root/VERSION")"
[[ "$source_version" == "$version" ]] || orm_die 'requested release version does not match the committed VERSION file.'

[[ "$private_key" == /* && -f "$private_key" && ! -L "$private_key" ]] \
    || orm_die 'private key must be an existing absolute regular file, not a symlink.'
private_key_real="$(realpath -e -- "$private_key")" || orm_die 'could not resolve private key path.'
[[ "$private_key_real" != "$repo_root" && "$private_key_real" != "$repo_root/"* ]] \
    || orm_die 'private signing key must be stored outside the repository.'
key_mode="$(stat -c '%a' -- "$private_key_real")" || orm_die 'could not inspect private key permissions.'
[[ "$key_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$key_mode & 0077) == 0 )) \
    || orm_die 'private signing key must not be accessible to group or other users.'
[[ -d "$output_directory" && ! -L "$output_directory" ]] \
    || orm_die 'output directory must already exist and must not be a symlink.'
output_directory="$(realpath -e -- "$output_directory")" || orm_die 'could not resolve output directory.'
[[ "$output_directory" != "$repo_root" && "$output_directory" != "$repo_root/"* ]] \
    || orm_die 'release output must be stored outside the repository.'
output_mode="$(stat -c '%a' -- "$output_directory")" || orm_die 'could not inspect output directory permissions.'
[[ "$output_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$output_mode & 0022) == 0 )) \
    || orm_die 'output directory must not be group or world writable.'

release_directory="$output_directory/orm-$version"
[[ ! -e "$release_directory" && ! -L "$release_directory" ]] || orm_die 'release output already exists; refusing to overwrite it.'
source_epoch="$(git -C "$repo_root" show -s --format=%ct HEAD)" || orm_die 'could not read the source commit timestamp.'
[[ "$source_epoch" =~ ^[0-9]{1,12}$ ]] || orm_die 'source commit timestamp is invalid.'
created_epoch="$(date -u '+%s')" || orm_die 'could not read the current UTC time.'
created_at="$(date -u -d "@$created_epoch" '+%Y-%m-%dT%H:%M:%SZ')" || orm_die 'could not format release creation time.'
expires_at="$(date -u -d "@$((created_epoch + valid_days * 86400))" '+%Y-%m-%dT%H:%M:%SZ')" \
    || orm_die 'could not format release expiry time.'

umask 077
work_directory="$(mktemp -d "$output_directory/.orm-release-$version.XXXXXXXX")" \
    || orm_die 'could not create a private release workspace.'
cleanup() {
    [[ -z "${work_directory:-}" || ! -d "$work_directory" ]] || rm -rf -- "$work_directory"
}
trap cleanup EXIT

stage="$work_directory/orm-$version"
mkdir -m 0755 -- "$stage"
while IFS= read -r relative_path || [[ -n "$relative_path" ]]; do
    [[ "$relative_path" =~ ^[A-Za-z0-9._/@-]+$ && "$relative_path" != *'..'* ]] \
        || orm_die 'required-file manifest contains an unsafe path.'
    source_file="$repo_root/$relative_path"
    [[ -f "$source_file" && ! -L "$source_file" ]] \
        || orm_die "required release file is missing or unsafe: $relative_path"
    target_file="$stage/$relative_path"
    mkdir -p -- "$(dirname -- "$target_file")"
    if [[ "$relative_path" == VERSION ]]; then
        printf '%s\n' "$version" >"$target_file"
    else
        cp -- "$source_file" "$target_file"
    fi
    chmod 0644 -- "$target_file"
done <"$package_root/release-required-files.txt"
find "$stage" -type d -exec chmod 0755 {} +

archive_path="$work_directory/orm-$version.tar.gz"
tar --format=gnu --sort=name --mtime="@$source_epoch" --owner=0 --group=0 --numeric-owner \
    -cf - -C "$work_directory" "orm-$version" | gzip -n -9 >"$archive_path"
chmod 0644 -- "$archive_path"
archive_size="$(stat -c '%s' -- "$archive_path")" || orm_die 'could not measure release archive.'
[[ "$archive_size" =~ ^[1-9][0-9]{0,8}$ && "$archive_size" -le "$ORM_RELEASE_ARTIFACT_MAX_BYTES" ]] \
    || orm_die 'release archive exceeds the verifier size limit.'
archive_digest="$(sha256sum -- "$archive_path" | awk '{print $1}')" || orm_die 'could not hash release archive.'

metadata_path="$work_directory/release.metadata"
{
    printf 'orm-release-metadata-v1\n'
    printf 'product|orm\nkey_id|%s\nversion|%s\nchannel|%s\n' "$key_id" "$version" "$channel"
    printf 'artifact|orm-%s.tar.gz\nartifact_size|%s\nartifact_sha256|%s\n' "$version" "$archive_size" "$archive_digest"
    printf 'min_from_version|%s\nmax_from_version|%s\ncreated_at|%s\nexpires_at|%s\n' \
        "$minimum_version" "$maximum_version" "$created_at" "$expires_at"
} >"$metadata_path"
chmod 0644 -- "$metadata_path"

private_bits="$(openssl rsa -in "$private_key_real" -check -noout -text 2>/dev/null \
    | sed -nE '1s/.*\(([0-9]+) bit([,)]).*/\1/p')" || orm_die 'private key is not a valid RSA key.'
[[ "$private_bits" =~ ^[0-9]+$ ]] && (( private_bits >= 3072 )) \
    || orm_die 'private RSA signing key must be at least 3072 bits.'
public_key_path="$work_directory/$key_id.pem"
openssl rsa -in "$private_key_real" -pubout -out "$public_key_path" >/dev/null 2>&1 \
    || orm_die 'could not derive the public key for this release.'
chmod 0644 -- "$public_key_path"
openssl dgst -sha256 -sign "$private_key_real" -out "$work_directory/release.sig" "$metadata_path" \
    || orm_die 'could not sign release metadata.'
chmod 0644 -- "$work_directory/release.sig"
"$ORM_PERL" "$package_root/inspect-release-archive.pl" "$archive_path" "$version" >/dev/null \
    || orm_die 'built archive did not pass the release archive inspector.'
openssl dgst -sha256 -verify "$public_key_path" -signature "$work_directory/release.sig" "$metadata_path" >/dev/null \
    || orm_die 'built release signature did not verify with its derived public key.'

bundle_stage="$work_directory/bundle"
mkdir -m 0755 -- "$bundle_stage"
cp -- "$archive_path" "$metadata_path" "$work_directory/release.sig" "$public_key_path" "$bundle_stage/"
chmod 0644 -- "$bundle_stage"/*
mv -T -- "$bundle_stage" "$release_directory" || orm_die 'could not publish complete release bundle.'
cleanup
work_directory=''
printf 'Built ORM %s (%s), key %s.\nBundle: %s\n' "$version" "$channel" "$key_id" "$release_directory"
printf 'Install the public key as /etc/orm/release-keys/%s.pem; keep the private key offline.\n' "$key_id"
