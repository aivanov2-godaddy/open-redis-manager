#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'release apply tests must run as root.\n' >&2; exit 1; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/packaging/lib.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-release-apply-test.XXXXXXXX")"
chmod 0700 "$test_root"
trap 'rm -rf -- "$test_root"' EXIT
key_dir="$test_root/trusted-keys"
private_key="$test_root/private.pem"
metadata="$test_root/release.metadata"
signature="$test_root/release.sig"
release_version='0.2.0'
installed_version='0.1.0-dev'
artifact="$test_root/orm-${release_version}.tar.gz"
release_root="$test_root/orm-$release_version"
target_root="$test_root/targets"
manifest="$test_root/installed-manifest"

mkdir -m 0700 "$key_dir"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key" >/dev/null 2>&1
openssl pkey -in "$private_key" -pubout -out "$key_dir/test-release.pem"
chmod 0600 "$private_key"
chmod 0644 "$key_dir/test-release.pem"

mkdir -p "$release_root"
printf '%s\n' "$release_version" >"$release_root/VERSION"
while IFS= read -r relative; do
    [[ "$relative" == VERSION ]] && continue
    mkdir -p "$release_root/$(dirname -- "$relative")"
    cp -- "$repo_root/$relative" "$release_root/$relative"
    chmod 0644 "$release_root/$relative"
done <"$repo_root/packaging/release-required-files.txt"
while IFS= read -r directory; do chmod 0755 "$directory"; done < <(find "$release_root" -type d -print)
chmod 0644 "$release_root/VERSION"
tar -czf "$artifact" -C "$test_root" "orm-$release_version"
future_expiry="$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
artifact_size="$(stat -c '%s' "$artifact")"
artifact_digest="$(sha256sum "$artifact" | awk '{print $1}')"
{
    printf 'orm-release-metadata-v1\n'
    printf 'product|orm\nkey_id|test-release\nversion|%s\nchannel|stable\n' "$release_version"
    printf 'artifact|orm-%s.tar.gz\nartifact_size|%s\nartifact_sha256|%s\n' "$release_version" "$artifact_size" "$artifact_digest"
    printf 'min_from_version|%s\nmax_from_version|%s\n' "$installed_version" "$installed_version"
    printf 'created_at|%s\nexpires_at|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$future_expiry"
} >"$metadata"
chmod 0600 "$metadata"
openssl dgst -sha256 -sign "$private_key" -out "$signature" "$metadata"
chmod 0600 "$signature"

prepare_installation() {
    local root="$1" target_manifest="$2" key source target mode installed_file digest
    rm -rf -- "$root" "$target_manifest"
    mkdir -m 0700 "$root"
    printf 'orm-install-manifest-v3\nversion|%s\n' "$installed_version" >"$target_manifest"
    while IFS='|' read -r key source target mode; do
        installed_file="$root$target"
        mkdir -p "$(dirname -- "$installed_file")"
        case "$key" in
            cpanel_entry|whm_cgi) printf 'old %s revision\n' "$key" >"$installed_file" ;;
            whm_appconfig)
                cat -- "$release_root/$source" >"$installed_file"
                printf '\nname=open_redis_manager\n' >>"$installed_file"
                ;;
            *) cp -- "$release_root/$source" "$installed_file" ;;
        esac
        chmod "$mode" "$installed_file"
        digest="$(sha256sum -- "$installed_file" | awk '{print $1}')"
        printf '%s|%s|%s|%s\n' "$key" "$mode" "$digest" "$target" >>"$target_manifest"
    done <"$repo_root/packaging/release-install-map.txt"
    chmod 0600 "$target_manifest"
    mkdir -p "$root/etc/orm-instances" "$root/var/lib/orm-instances/send" "$root/var/cpanel/orm"
    printf 'account-state-fixture\n' >"$root/etc/orm-instances/send.json"
    printf 'redis-rdb-fixture\n' >"$root/var/lib/orm-instances/send/dump.rdb"
    printf 'podman\n' >"$root/var/cpanel/orm/provider-backend-policy"
}

tree_snapshot() {
    local root="$1"
    {
        find "$root" -path "$root/var/cpanel/orm/updates" -prune -o -printf '%P|%y|%u|%g|%m|%s\n' | sort
        find "$root" -path "$root/var/cpanel/orm/updates" -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum
    }
}

first_target="$(awk -F'|' '$1 == "cpanel_entry" { print $3 }' "$repo_root/packaging/release-install-map.txt")"
second_target="$(awk -F'|' '$1 == "whm_cgi" { print $3 }' "$repo_root/packaging/release-install-map.txt")"
broker_target="$(awk -F'|' '$1 == "broker_handler" { print $3 }' "$repo_root/packaging/release-install-map.txt")"

# A local edit is a conflict and must be rejected before any mutation.
prepare_installation "$target_root" "$manifest"
printf 'locally modified by operator\n' >"$target_root$second_target"
before_conflict="$(tree_snapshot "$target_root")"
if bash "$repo_root/packaging/apply-release.sh" "$metadata" "$signature" "$artifact" "$key_dir" "$installed_version" "$manifest" "$target_root" >/dev/null 2>&1; then
    printf 'release apply accepted a locally modified target.\n' >&2
    exit 1
fi
[[ "$before_conflict" == "$(tree_snapshot "$target_root")" ]] || {
    printf 'conflict preflight mutated the installation fixture.\n' >&2
    exit 1
}

# Broker changes are not applied by the fixture transaction; they must fail before mutation.
prepare_installation "$target_root" "$manifest"
printf 'old broker revision\n' >"$target_root$broker_target"
broker_digest="$(sha256sum "$target_root$broker_target" | awk '{print $1}')"
awk -F'|' -v digest="$broker_digest" 'BEGIN { OFS = "|" } $1 == "broker_handler" { $3 = digest } { print }' \
    "$manifest" >"$manifest.next"
mv -- "$manifest.next" "$manifest"
before_broker_refusal="$(tree_snapshot "$target_root")"
if bash "$repo_root/packaging/apply-release.sh" "$metadata" "$signature" "$artifact" "$key_dir" "$installed_version" "$manifest" "$target_root" >/dev/null 2>&1; then
    printf 'release apply accepted an unsupported broker update.\n' >&2
    exit 1
fi
[[ "$before_broker_refusal" == "$(tree_snapshot "$target_root")" ]] || {
    printf 'unsupported broker update mutated the installation fixture.\n' >&2
    exit 1
}

# Fail the second atomic install after the first target changed; rollback must be exact.
prepare_installation "$target_root" "$manifest"
real_install="$(command -v install)"
base_path="$PATH"
mkdir -p "$test_root/fail-bin"
cat >"$test_root/fail-bin/install" <<'SH'
#!/usr/bin/env bash
set -e
if [[ "${1:-}" == -m && "${4:-}" == *'/stage/orm-'* ]]; then
    count=0
    [[ ! -f "$TEST_INSTALL_COUNT" ]] || count="$(cat "$TEST_INSTALL_COUNT")"
    ((count += 1))
    printf '%s\n' "$count" >"$TEST_INSTALL_COUNT"
    [[ "$count" -ne 2 ]] || exit 73
fi
exec "$TEST_REAL_INSTALL" "$@"
SH
chmod 0755 "$test_root/fail-bin/install"
before_rollback="$(tree_snapshot "$target_root")"
export TEST_INSTALL_COUNT="$test_root/install-count"
export TEST_REAL_INSTALL="$real_install"
export PATH="$test_root/fail-bin:$PATH"
if bash "$repo_root/packaging/apply-release.sh" "$metadata" "$signature" "$artifact" "$key_dir" "$installed_version" "$manifest" "$target_root" >"$test_root/rollback.out" 2>&1; then
    printf 'release apply ignored the injected replacement failure.\n' >&2
    exit 1
fi
PATH="$base_path"
export PATH
unset TEST_INSTALL_COUNT TEST_REAL_INSTALL
[[ "$before_rollback" == "$(tree_snapshot "$target_root")" && "$(orm_install_manifest_version "$manifest")" == "$installed_version" ]] || {
    printf 'failed apply did not restore managed files, account state, and manifest.\n' >&2
    exit 1
}
[[ -z "$(find "$target_root/var/cpanel/orm/updates" -mindepth 1 -maxdepth 1 -name 'transaction.*' -print -quit 2>/dev/null)" ]] || {
    printf 'successful rollback left stale updater state.\n' >&2
    exit 1
}
grep -q '"outcome":"rolled_back"' "$target_root/var/cpanel/orm/updates/update-audit.jsonl" || {
    printf 'rollback outcome was not recorded in the updater audit log; current contents follow:\n' >&2
    cat "$target_root/var/cpanel/orm/updates/update-audit.jsonl" >&2
    printf 'updater output follows:\n' >&2
    cat "$test_root/rollback.out" >&2
    exit 1
}

# A clean fixture applies and advances the v3 manifest without touching service data.
prepare_installation "$target_root" "$manifest"
bash "$repo_root/packaging/apply-release.sh" "$metadata" "$signature" "$artifact" "$key_dir" "$installed_version" "$manifest" "$target_root" >"$test_root/apply.out"
[[ "$(orm_install_manifest_version "$manifest")" == "$release_version" ]] || {
    printf 'successful apply did not advance the installed manifest version.\n' >&2
    exit 1
}
for target in "$first_target" "$second_target"; do
    source="$(awk -F'|' -v target="$target" '$3 == target { print $2 }' "$repo_root/packaging/release-install-map.txt")"
    cmp -s "$release_root/$source" "$target_root$target" || {
        printf 'successful apply did not install %s.\n' "$target" >&2
        exit 1
    }
done
[[ "$(cat "$target_root/etc/orm-instances/send.json")" == account-state-fixture
    && "$(cat "$target_root/var/lib/orm-instances/send/dump.rdb")" == redis-rdb-fixture
    && "$(cat "$target_root/var/cpanel/orm/provider-backend-policy")" == podman ]] || {
    printf 'apply changed account state, Redis data, or backend selection.\n' >&2
    exit 1
}
[[ -z "$(find "$target_root/var/cpanel/orm/updates" -mindepth 1 -maxdepth 1 -name 'transaction.*' -print -quit 2>/dev/null)" ]] || {
    printf 'successful apply left stale updater state.\n' >&2
    exit 1
}
grep -q '"outcome":"success"' "$target_root/var/cpanel/orm/updates/update-audit.jsonl" || {
    printf 'successful update outcome was not recorded in the updater audit log.\n' >&2
    exit 1
}

printf 'Signed release apply and rollback checks passed.\n'
