#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
source "$ORM_PACKAGE_ROOT/release-lib.sh"

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: sudo bash packaging/apply-release.sh METADATA SIGNATURE ARCHIVE TRUSTED_KEY_DIR INSTALLED_VERSION [INSTALL_MANIFEST [TEST_TARGET_ROOT [EXPECTED_CANDIDATE_VERSION EXPECTED_ARTIFACT_SHA256]]]\n'
    printf 'Applies a verified release to an exact, conflict-free v3 installation. Test root remaps fixed targets for Linux fixtures.\n'
    exit 0
fi
[[ $# -ge 5 && $# -le 9 ]] || orm_die 'expected metadata, signature, archive, trusted key directory, installed version, and optional manifest/test root/release identity.'
[[ "$(id -u)" -eq 0 ]] || orm_die 'run release apply as root.'

metadata="$1"
signature="$2"
archive="$3"
trusted_key_dir="$4"
installed_version="$5"
install_manifest="${6:-$ORM_INSTALL_MANIFEST}"
test_target_root="${7:-}"
expected_candidate_version="${8:-}"
expected_artifact_sha256="${9:-}"
[[ ( -z "$expected_candidate_version" && -z "$expected_artifact_sha256" ) \
    || ( -n "$expected_candidate_version" && -n "$expected_artifact_sha256" ) ]] \
    || orm_die 'expected candidate version and artifact digest must be supplied together.'
if [[ -n "$expected_candidate_version" ]]; then
    [[ "$expected_candidate_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] \
        || orm_die 'expected candidate version is invalid.'
    [[ "$expected_artifact_sha256" =~ ^[a-f0-9]{64}$ ]] \
        || orm_die 'expected artifact digest is invalid.'
fi
if [[ -n "$test_target_root" ]]; then
    [[ "$test_target_root" == /* && -d "$test_target_root" && ! -L "$test_target_root" ]] \
        || orm_die 'test target root must be an existing absolute directory.'
    [[ "$(stat -c '%u:%a' -- "$test_target_root")" == "0:700" ]] \
        || orm_die 'test target root must be root-owned with mode 0700.'
else
    [[ "$install_manifest" == "$ORM_INSTALL_MANIFEST" ]] \
        || orm_die 'a custom installed manifest is permitted only with an explicit test target root.'
fi

orm_acquire_lifecycle_lock "$0" "$@"
[[ -n "$test_target_root" ]] || orm_require_root_and_platform

if [[ -z "$test_target_root" ]]; then
    orm_validate_install_manifest "$install_manifest" allow-known-subset \
        || orm_die 'the installed ORM manifest or one of its managed files failed integrity validation.'
    orm_registration_state || orm_die 'WHM AppConfig registration is missing or could not be verified.'
fi
[[ "$(orm_install_manifest_version "$install_manifest")" == "$installed_version" ]] \
    || orm_die 'the installed manifest version does not match the requested installed version.'

candidate_version="$(orm_release_metadata_verify \
    "$metadata" "$signature" "$archive" "$trusted_key_dir" "$installed_version")" \
    || orm_die 'signed release bundle verification failed; no files were changed.'
if [[ -n "$expected_candidate_version" ]]; then
    [[ "$candidate_version" == "$expected_candidate_version" ]] \
        || orm_die 'the signed candidate version no longer matches the confirmed preview; no files were changed.'
    current_artifact_sha256="$(awk -F'|' '$1 == "artifact_sha256" { print $2 }' "$metadata")" \
        || orm_die 'could not read the verified artifact identity; no files were changed.'
    [[ "$current_artifact_sha256" == "$expected_artifact_sha256" ]] \
        || orm_die 'the signed artifact no longer matches the confirmed preview; no files were changed.'
fi

if [[ -n "$test_target_root" ]]; then
    state_root="${test_target_root%/}/var/cpanel/orm/updates"
else
    state_root=/var/cpanel/orm/updates
fi
orm_safe_target_parent_chain "$state_root/.probe" \
    || orm_die 'the persistent updater state path has an unsafe parent.'
install -d -o root -g root -m 0700 -- "$state_root" \
    || orm_die 'could not create the protected persistent updater state directory.'
[[ -d "$state_root" && ! -L "$state_root" \
    && "$(stat -c '%u:%a' -- "$state_root")" == 0:700 ]] \
    || orm_die 'the persistent updater state directory must be root-owned with mode 0700.'
audit_file="$state_root/update-audit.jsonl"
[[ ! -L "$audit_file" && ( ! -e "$audit_file" || -f "$audit_file" ) ]] \
    || orm_die 'the updater audit path is unsafe.'
if [[ ! -e "$audit_file" ]]; then (umask 077; : >"$audit_file") || orm_die 'could not initialize the updater audit log.'; fi
chown root:root -- "$audit_file" && chmod 0600 -- "$audit_file" \
    || orm_die 'could not secure the updater audit log.'
[[ "$(stat -c '%u:%a' -- "$audit_file")" == 0:600 \
    && "$(stat -c '%s' -- "$audit_file")" -le 1048576 ]] \
    || orm_die 'the updater audit log is unsafe or full.'
stale_transaction="$(find "$state_root" -mindepth 1 -maxdepth 1 -name 'transaction.*' -print -quit)"
[[ -z "$stale_transaction" ]] \
    || orm_die 'an unfinished updater transaction exists; inspect its recovery journal before retrying.'
workspace="$(mktemp -d "$state_root/transaction.XXXXXXXX")" \
    || orm_die 'could not create a private update workspace.'
chmod 0700 -- "$workspace"
chown root:root -- "$workspace"
staging="$workspace/stage"
backup_root="$workspace/backup"
mkdir -m 0700 -- "$staging" "$backup_root"
preview_file="$workspace/preview.json"
actions_file="$workspace/actions.txt"
manifest_new="$workspace/install-manifest.new"
manifest_backup="$workspace/install-manifest.old"
mutated=0
transaction_succeeded=0
keep_backup=0
copied_count=0
broker_related_change=0
broker_state_captured=0
new_manifest_installed=0
declare -a changed_keys=()
declare -a changed_targets=()
declare -a changed_actions=()
declare -a created_directories=()

append_audit() {
    local outcome="$1" timestamp audit_size record artifact_digest
    [[ "$candidate_version" =~ ^[0-9A-Za-z.+-]+$ ]] || return 1
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
    artifact_digest="$(awk -F'|' '$1 == "artifact_sha256" { print $2 }' "$metadata")" || return 1
    exec {audit_fd}>>"$audit_file" || return 1
    flock -x "$audit_fd" || { exec {audit_fd}>&-; return 1; }
    audit_size="$(stat -c '%s' -- "$audit_file")" || { exec {audit_fd}>&-; return 1; }
    (( audit_size <= 1048000 )) || { exec {audit_fd}>&-; return 1; }
    record="$("$ORM_PERL" -MJSON::PP -e '
        my ($timestamp, $from, $to, $digest, $outcome) = @ARGV;
        print JSON::PP->new->canonical->encode({
            actor => "root", artifactSha256 => $digest, event => "release.update",
            fromVersion => $from, outcome => $outcome, timestamp => $timestamp,
            toVersion => $to,
        }), "\n";
    ' "$timestamp" "$installed_version" "$candidate_version" "$artifact_digest" "$outcome")" \
        || { exec {audit_fd}>&-; return 1; }
    printf '%s' "$record" >&"$audit_fd" || { exec {audit_fd}>&-; return 1; }
    flock -u "$audit_fd" || { exec {audit_fd}>&-; return 1; }
    exec {audit_fd}>&-
}

physical_target() {
    local target="$1"
    if [[ -n "$test_target_root" ]]; then
        printf '%s%s\n' "${test_target_root%/}" "$target"
    else
        printf '%s\n' "$target"
    fi
}

rollback_release() {
    local rollback_failed=0 index key target action saved current_digest
    for ((index = ${#changed_keys[@]} - 1; index >= 0; index -= 1)); do
        key="${changed_keys[$index]}"
        target="${changed_targets[$index]}"
        action="${changed_actions[$index]}"
        if [[ "$action" == add ]]; then
            if [[ -f "$target" && ! -L "$target" ]]; then
                current_digest="$(sha256sum -- "$target" | awk '{print $1}')" || { rollback_failed=1; continue; }
                if [[ "$current_digest" == "${candidate_digest[$key]:-}" ]]; then
                    rm -f -- "$target" || rollback_failed=1
                else
                    rollback_failed=1
                fi
            elif [[ -e "$target" || -L "$target" ]]; then
                rollback_failed=1
            fi
        elif [[ -f "$backup_root/$key" && ! -L "$backup_root/$key" ]]; then
            [[ -f "$target" && ! -L "$target" ]] || { rollback_failed=1; continue; }
            current_digest="$(sha256sum -- "$target" | awk '{print $1}')" || { rollback_failed=1; continue; }
            [[ "$current_digest" == "${candidate_digest[$key]:-}" ]] || { rollback_failed=1; continue; }
            saved="$(mktemp "$(dirname -- "$target")/.orm-update-rollback.XXXXXXXX")" || { rollback_failed=1; continue; }
            if cp -a -- "$backup_root/$key" "$saved" && mv -f -- "$saved" "$target"; then
                :
            else
                rm -f -- "$saved"
                rollback_failed=1
            fi
        else
            rollback_failed=1
        fi
    done
    if [[ "$new_manifest_installed" -eq 1 ]]; then
        if [[ -f "$install_manifest" && ! -L "$install_manifest" && -f "$manifest_backup" && ! -L "$manifest_backup" ]]; then
            saved="$(mktemp "$(dirname -- "$install_manifest")/.orm-manifest-rollback.XXXXXXXX")" \
                || rollback_failed=1
            if [[ -n "${saved:-}" ]] && cp -a -- "$manifest_backup" "$saved" && mv -f -- "$saved" "$install_manifest"; then
                :
            else
                [[ -z "${saved:-}" ]] || rm -f -- "$saved"
                rollback_failed=1
            fi
        else
            rollback_failed=1
        fi
    fi
    if (( broker_related_change )); then
        "$ORM_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || rollback_failed=1
        if [[ "${ORM_BROKER_ACTIVE_BEFORE:-}" == active ]]; then
            "$ORM_SYSTEMCTL" start orm-broker.service >/dev/null 2>&1 || rollback_failed=1
            [[ "$test_target_root" != "" ]] || orm_wait_for_broker_socket || rollback_failed=1
        fi
    fi
    if (( broker_state_captured )) && ! orm_broker_health_matches_initial; then
        rollback_failed=1
    fi
    for target in "${created_directories[@]}"; do rmdir -- "$target" 2>/dev/null || true; done
    if [[ "$rollback_failed" -ne 0 ]]; then
        keep_backup=1
        printf 'ORM updater: rollback was incomplete; protected recovery material was retained at %s.\n' "$workspace" >&2
        return 1
    fi
    return 0
}

cleanup_release() {
    local status=$?
    trap - EXIT
    if [[ "$status" -ne 0 && "$transaction_succeeded" -eq 0 && "$mutated" -eq 1 ]]; then
        write_journal rolling_back || true
        if rollback_release; then
            append_audit rolled_back || { printf 'ORM updater: rollback completed but its audit record could not be written.\n' >&2; status=1; }
        else
            append_audit recovery_required || printf 'ORM updater: recovery is required, but its audit record could not be written.\n' >&2
            status=1
        fi
    elif [[ "$status" -ne 0 && "$transaction_succeeded" -eq 0 && -n "$candidate_version" ]]; then
        append_audit rejected || true
    fi
    if [[ "$status" -ne 0 && "$transaction_succeeded" -eq 0 && "$keep_backup" -eq 0 ]]; then
        rm -rf -- "$workspace"
    elif [[ "$transaction_succeeded" -eq 1 ]]; then
        rm -rf -- "$workspace"
    fi
    exit "$status"
}
trap cleanup_release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_preview() {
    local inventory
    candidate_version="$(orm_release_metadata_verify \
        "$metadata" "$signature" "$archive" "$trusted_key_dir" "$installed_version")" \
        || orm_die 'signed release verification failed during locked preflight.'
    inventory="$("$ORM_PERL" "$ORM_PACKAGE_ROOT/inspect-release-archive.pl" \
        "$archive" "$candidate_version" --json)" \
        || orm_die 'release archive verification failed during locked preflight.'
    printf '%s\n' "$inventory" | "$ORM_PERL" "$ORM_PACKAGE_ROOT/compare-release-preview.pl" \
        "$install_manifest" "$installed_version" "$metadata" ${test_target_root:+"$test_target_root"} >"$preview_file" \
        || orm_die 'installed-file preview failed during locked preflight.'
    "$ORM_PERL" -MJSON::PP -e '
        local $/;
        my $preview = decode_json(<STDIN>);
        my $summary = $preview->{summary};
        ref($summary) eq "HASH" or die "invalid preview summary\n";
        for my $key (qw(conflict move retire)) {
            ($summary->{$key} // 0) == 0 or die "preview requires review\n";
        }
        ref($preview->{migrationActions}) eq "ARRAY" && !@{$preview->{migrationActions}}
            or die "release contains unsupported migration actions\n";
        ref($preview->{fileActions}) eq "ARRAY" or die "invalid preview actions\n";
        for my $action (@{$preview->{fileActions}}) {
            $action->{action} =~ /\A(?:add|replace|unchanged)\z/
                or die "preview contains an unsupported action\n";
        }
        print JSON::PP->new->canonical->encode($preview), "\n";
    ' <"$preview_file" >"$workspace/checked-preview.json" \
        || orm_die 'release changes include conflicts, file moves, retirements, or unsupported migrations.'
    mv -f -- "$workspace/checked-preview.json" "$preview_file"
    "$ORM_PERL" -MJSON::PP -e '
        local $/;
        my $preview = decode_json(<STDIN>);
        for my $action (@{$preview->{fileActions}}) {
            for my $field (qw(key action target mode sha256)) {
                defined($action->{$field}) or die "preview action is incomplete\n";
            }
            my $source = $action->{source} // q{};
            $source =~ /\A[A-Za-z0-9._\/\@-]*\z/ or die "unsafe archive source\n";
            join(q{|}, @{$action}{qw(key action)}, $source,
                @{$action}{qw(target mode sha256)}) =~ /\A[a-z_]+\|(?:add|replace|unchanged)\|[^|]*\|\/[^|]+\|(?:600|644|755)\|[a-f0-9]{64}\z/
                or die "unsafe preview row\n";
            print join(q{|}, @{$action}{qw(key action)}, $source,
                @{$action}{qw(target mode sha256)}), "\n";
        }
    ' <"$preview_file" >"$actions_file" \
        || orm_die 'release preview contains an invalid file action.'
}

write_journal() {
    local phase="$1" temporary_journal
    temporary_journal="$(mktemp "$workspace/.journal.XXXXXXXX")" || return 1
    {
        printf 'orm-update-transaction-v1\n'
        printf 'installed_version|%s\n' "$installed_version"
        printf 'candidate_version|%s\n' "$candidate_version"
        printf 'artifact_sha256|%s\n' "$(awk -F'|' '$1 == "artifact_sha256" { print $2 }' "$metadata")"
        printf 'phase|%s\n' "$phase"
        if [[ -f "$actions_file" ]]; then cat -- "$actions_file"; fi
    } >"$temporary_journal"
    chmod 0600 -- "$temporary_journal"
    chown root:root -- "$temporary_journal"
    mv -f -- "$temporary_journal" "$workspace/journal"
}

# Verify and compare while holding the same lock used by install and uninstall.
write_preview
tar --extract --gzip --file "$archive" --directory "$staging" \
    --no-same-owner --no-same-permissions "orm-$candidate_version" \
    || orm_die 'verified release could not be staged.'
release_root="$staging/orm-$candidate_version"
[[ -f "$release_root/packaging/release-install-map.txt" && ! -L "$release_root/packaging/release-install-map.txt" ]] \
    || orm_die 'staged release is missing its signed install map.'
orm_release_install_map_is_compatible "$release_root/packaging/release-install-map.txt" "$ORM_PACKAGE_ROOT/release-install-map.txt" \
    || orm_die 'staged release install map differs from the updater allowlist.'

declare -A candidate_digest=() installed_digest=() installed_mode=() action_for_key=() target_for_key=() mode_for_key=() source_for_key=()
while IFS='|' read -r key action source target mode digest; do
    [[ "$key" =~ ^[a-z_]+$ && "$target" == /* && "$mode" =~ ^(600|644|755)$ && "$digest" =~ ^[a-f0-9]{64}$ ]] \
        || orm_die 'preview contains an invalid target record.'
    action_for_key[$key]="$action"
    target_for_key[$key]="$target"
    mode_for_key[$key]="$mode"
    source_for_key[$key]="$source"
    candidate_digest[$key]="$digest"
done <"$actions_file"

while IFS='|' read -r key mode digest target extra; do
    [[ "$key" =~ ^[a-z_]+$ && "$mode" =~ ^(600|644|755)$ && "$digest" =~ ^[a-f0-9]{64}$ \
        && "$target" == /* && -z "${extra:-}" ]] || orm_die 'installed manifest contains an invalid record.'
    installed_digest[$key]="$digest"
    installed_mode[$key]="$mode"
done < <(awk 'NR > 2 { print }' "$install_manifest")

while IFS='|' read -r key action source target mode digest; do
    physical="$(physical_target "$target")"
    if [[ "$key" == whm_appconfig ]]; then
        [[ "$action" == replace || "$action" == unchanged ]] \
            || orm_die 'WHM AppConfig registration cannot be added or removed by this update path.'
        candidate_file="$release_root/$source"
        [[ -f "$candidate_file" && ! -L "$candidate_file" && -f "$physical" && ! -L "$physical" ]] \
            || orm_die 'WHM AppConfig source or registration is missing or unsafe.'
        cmp -s -- "$physical" <(cat -- "$candidate_file"; printf '\nname=open_redis_manager\n') \
            || orm_die 'release changes WHM AppConfig; registration changes require a separate cPanel transaction.'
        continue
    fi
    case "$key:$action" in
        broker_*:unchanged|broker_bin:unchanged|broker_unit:unchanged|instance_unit:unchanged|metrics_service:unchanged|metrics_timer:unchanged) ;;
        broker_*:*|broker_bin:*|broker_unit:*|instance_unit:*|metrics_service:*|metrics_timer:*)
            broker_related_change=1
            ;;
    esac
    orm_safe_target_parent_chain "$physical" || orm_die 'installed target parent chain is unsafe.'
    if [[ "$action" == add ]]; then
        [[ ! -e "$physical" && ! -L "$physical" ]] || orm_die 'an add target appeared after preview; refusing to overwrite it.'
    else
        [[ -f "$physical" && ! -L "$physical" ]] || orm_die 'an installed target changed after preview.'
        [[ "$(stat -c '%u' -- "$physical")" == 0 \
            && "$(stat -c '%a' -- "$physical")" == "${installed_mode[$key]:-}" \
            && "$(sha256sum -- "$physical" | awk '{print $1}')" == "${installed_digest[$key]:-}" ]] \
            || orm_die 'an installed file changed after preview; no files were changed.'
    fi
    candidate_file="$release_root/$source"
    [[ -f "$candidate_file" && ! -L "$candidate_file" ]] || orm_die 'a verified install source is missing or unsafe.'
    [[ "$(sha256sum -- "$candidate_file" | awk '{print $1}')" == "$digest" ]] \
        || orm_die 'a staged file differs from its verified release inventory.'
done <"$actions_file"

if (( broker_related_change )); then
    [[ -z "$test_target_root" ]] || orm_die 'the fixture apply path does not exercise broker restart and socket-drain behavior.'
fi
if [[ -z "$test_target_root" ]]; then
    orm_capture_broker_state || orm_die 'could not determine broker state before update.'
    broker_state_captured=1
    orm_broker_health_matches_initial \
        || orm_die 'the broker service state or active socket is not healthy before update.'
    if (( broker_related_change )) && [[ "$ORM_BROKER_ACTIVE_BEFORE" == active ]]; then
        orm_die 'this transaction slice refuses broker or systemd updates while the broker is active; use the maintenance procedure.'
    fi
fi

cp -a -- "$install_manifest" "$manifest_backup"
chmod 0600 -- "$manifest_backup"
chown root:root -- "$manifest_backup"
while IFS='|' read -r key action source target mode digest; do
    [[ "$action" == unchanged || "$key" == whm_appconfig ]] && continue
    physical="$(physical_target "$target")"
    if [[ "$action" == replace ]]; then
        cp -a -- "$physical" "$backup_root/$key" || orm_die 'could not snapshot an ORM-managed target.'
    fi
done <"$actions_file"

write_journal applying || orm_die 'could not record the durable update recovery journal.'
mutated=1
while IFS='|' read -r key action source target mode digest; do
    [[ "$action" == unchanged || "$key" == whm_appconfig ]] && continue
    physical="$(physical_target "$target")"
    parent="$(dirname -- "$physical")"
    if [[ ! -d "$parent" ]]; then
        mkdir -p -m 0755 -- "$parent" || orm_die 'could not create an allowed ORM target directory.'
        created_directories+=("$parent")
    fi
    orm_safe_target_parent_chain "$physical" || orm_die 'target directory changed during update.'
    if [[ "$action" == add ]]; then
        [[ ! -e "$physical" && ! -L "$physical" ]] || orm_die 'an add target changed immediately before installation.'
    else
        [[ -f "$physical" && ! -L "$physical" \
            && "$(stat -c '%u' -- "$physical")" == 0 \
            && "$(stat -c '%a' -- "$physical")" == "${installed_mode[$key]:-}" \
            && "$(sha256sum -- "$physical" | awk '{print $1}')" == "${installed_digest[$key]:-}" ]] \
            || orm_die 'an installed target changed immediately before replacement.'
    fi
    temporary="$(mktemp "$parent/.orm-update.XXXXXXXX")" || orm_die 'could not create an atomic target file.'
    if ! install -m "$mode" -- "$release_root/$source" "$temporary" \
        || ! chown root:root -- "$temporary" \
        || ! mv -f -- "$temporary" "$physical"; then
        rm -f -- "$temporary"
        orm_die 'an ORM-managed target could not be atomically replaced.'
    fi
    changed_keys+=("$key")
    changed_targets+=("$physical")
    changed_actions+=("$action")
    ((copied_count += 1))
    write_journal "applied_${copied_count}" || orm_die 'could not advance the durable update recovery journal.'
done <"$actions_file"

if (( broker_related_change )); then
    "$ORM_SYSTEMCTL" daemon-reload || orm_die 'systemd could not reload updated ORM units.'
fi

{
    printf 'orm-install-manifest-v3\nversion|%s\n' "$candidate_version"
    while IFS='|' read -r key action source target mode digest; do
        physical="$(physical_target "$target")"
        if [[ "$key" == whm_appconfig ]]; then
            digest="$(sha256sum -- "$physical" | awk '{print $1}')" || orm_die 'could not hash registered WHM AppConfig.'
            [[ "$digest" == "${installed_digest[$key]:-}" ]] \
                || orm_die 'registered WHM AppConfig changed after preflight.'
        else
            digest="$(sha256sum -- "$physical" | awk '{print $1}')" || orm_die 'could not hash an updated ORM file.'
            [[ "$(stat -c '%u:%a' -- "$physical")" == "0:$mode" ]] || orm_die 'updated ORM file ownership or mode is invalid.'
            [[ "$digest" == "${candidate_digest[$key]:-}" ]] \
                || orm_die 'an installed ORM file does not match the signed release content.'
        fi
        printf '%s|%s|%s|%s\n' "$key" "$mode" "$digest" "$target"
    done <"$actions_file"
} >"$manifest_new"
chmod 0600 -- "$manifest_new"
chown root:root -- "$manifest_new"
[[ -n "$test_target_root" ]] && manifest_directory="$(dirname -- "$install_manifest")" || manifest_directory="$(dirname -- "$ORM_INSTALL_MANIFEST")"
temporary_manifest="$(mktemp "$manifest_directory/.orm-update-manifest.XXXXXXXX")" \
    || orm_die 'could not create the new installed manifest.'
cp -- "$manifest_new" "$temporary_manifest"
chmod 0600 -- "$temporary_manifest"
chown root:root -- "$temporary_manifest"
mv -f -- "$temporary_manifest" "$install_manifest"
new_manifest_installed=1
write_journal manifest_written || orm_die 'could not record the updated manifest in the recovery journal.'

if [[ -z "$test_target_root" ]]; then
    orm_validate_install_manifest "$install_manifest" || orm_die 'updated manifest verification failed.'
    orm_appconfig_matches_package "$ORM_APPCONFIG" || orm_die 'WHM AppConfig changed during update.'
    orm_registration_state || orm_die 'WHM registration could not be verified after update.'
    orm_broker_health_matches_initial \
        || orm_die 'broker service state or active socket readiness changed during update.'
fi

write_journal complete || orm_die 'could not record update completion in the recovery journal.'
append_audit success || orm_die 'could not record the completed update in the protected audit log.'
transaction_succeeded=1
printf 'Open Redis Manager files updated from %s to %s. Managed files, package version, WHM registration, broker service state, and active broker socket readiness were verified. Redis/Valkey instance data and backend selection were not changed.\n' \
    "$installed_version" "$candidate_version"
