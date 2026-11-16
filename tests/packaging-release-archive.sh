#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'release archive tests must run as root.\n' >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ORM_PERL="${ORM_PERL:-/usr/bin/perl}"
source "$repo_root/packaging/lib.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-release-archive-test.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
version='0.2.0'
release_root="$test_root/orm-$version"
archive="$test_root/orm-$version.tar.gz"

prepare_release() {
    local path
    rm -rf -- "$release_root" "$archive"
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
}

make_archive() {
    tar -czf "$archive" -C "$test_root" "orm-$version"
}

expect_rejected() {
    local description="$1"
    if "$ORM_PERL" "$repo_root/packaging/inspect-release-archive.pl" "$archive" "$version" >/dev/null 2>&1; then
        printf 'release archive inspector accepted %s.\n' "$description" >&2
        exit 1
    fi
}

declare -A release_required=()
while IFS= read -r path; do
    [[ -n "$path" && -z "${release_required[$path]+present}" ]] \
        || { printf 'release required-file manifest contains a blank or duplicate entry.\n' >&2; exit 1; }
    release_required[$path]=1
done <"$repo_root/packaging/release-required-files.txt"
while IFS='|' read -r key source target mode; do
    relative_source="${source#"$ORM_REPO_ROOT/"}"
    [[ -n "${release_required[$relative_source]+present}" ]] \
        || { printf 'package file map entry is missing from release-required-files.txt: %s\n' "$relative_source" >&2; exit 1; }
done < <(orm_package_file_map)
while IFS='|' read -r key source target mode; do
    relative_source="${source#"$ORM_REPO_ROOT/"}"
    printf '%s|%s|%s|%s\n' "$key" "$relative_source" "$target" "$mode"
done < <(orm_package_file_map) >"$test_root/expected-install-map"
cmp -s -- "$test_root/expected-install-map" "$repo_root/packaging/release-install-map.txt" \
    || { printf 'signed release install map is out of sync with the package file map.\n' >&2; exit 1; }

prepare_release
make_archive
summary="$(perl "$repo_root/packaging/inspect-release-archive.pl" "$archive" "$version")"
[[ "$summary" =~ ^[0-9]+\|[0-9]+$ ]] \
    || { printf 'valid archive did not return bounded inventory counts.\n' >&2; exit 1; }

prepare_release
tar --format=pax --pax-option='comment=ORM structure fixture' -czf "$archive" -C "$test_root" "orm-$version"
perl "$repo_root/packaging/inspect-release-archive.pl" "$archive" "$version" >/dev/null \
    || { printf 'valid PAX metadata entry was rejected.\n' >&2; exit 1; }

prepare_release
truncate -s 67108865 "$release_root/oversized-member"
make_archive
expect_rejected 'a member larger than the per-file limit'

prepare_release
ln -s README.md "$release_root/symlink"
if [[ -L "$release_root/symlink" ]]; then
    make_archive
    expect_rejected 'a symbolic link'
else
    printf 'Skipping symbolic-link fixture: this filesystem does not preserve POSIX symlinks.\n'
fi

prepare_release
ln "$release_root/README.md" "$release_root/hardlink"
if [[ "$release_root/README.md" -ef "$release_root/hardlink" ]]; then
    make_archive
    expect_rejected 'a hard link'
else
    printf 'Skipping hard-link fixture: this filesystem does not preserve POSIX hard links.\n'
fi

prepare_release
if mkfifo "$release_root/fifo" 2>/dev/null; then
    make_archive
    expect_rejected 'a FIFO'
else
    printf 'Skipping FIFO fixture: this platform cannot create POSIX FIFOs.\n'
fi

prepare_release
printf 'unlisted payload\n' >"$release_root/unexpected-file"
make_archive
expect_rejected 'an unlisted archive file'

prepare_release
sed -i '1s#|/usr/local/cpanel/base/frontend/jupiter/orm/index.live.php|644$#|/etc/passwd|644#' \
    "$release_root/packaging/release-install-map.txt"
make_archive
expect_rejected 'an install target outside ORM-owned files'

prepare_release
sed -i '1s#|/usr/local/cpanel/base/frontend/jupiter/orm/index.live.php|644$#|/usr/local/cpanel/3rdparty/orm/bin/orm-unmanaged.pl|644#' \
    "$release_root/packaging/release-install-map.txt"
make_archive
expect_rejected 'an unmanaged file inside the ORM install tree'

prepare_release
tar -czf "$archive" -C "$test_root" \
    --transform="s#orm-$version/README.md#orm-$version/../outside#" "orm-$version"
expect_rejected 'a parent-directory traversal member'

prepare_release
long_component="$(printf '%120s' '' | tr ' ' x)"
tar --format=pax -czf "$archive" -C "$test_root" \
    --transform="s#orm-$version/README.md#orm-$version/../$long_component#" "orm-$version"
expect_rejected 'a PAX parent-directory traversal member'

prepare_release
tar -czf "$archive" -C "$test_root" "orm-$version/VERSION" "orm-$version/VERSION"
expect_rejected 'duplicate archive members'

prepare_release
rm "$release_root/packaging/upgrade.sh"
make_archive
expect_rejected 'a release missing a required package file'

prepare_release
printf '0.3.0\n' >"$release_root/VERSION"
make_archive
expect_rejected 'a VERSION file that differs from signed metadata'

printf 'Release archive structure checks passed.\n'
