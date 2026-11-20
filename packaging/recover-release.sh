#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

usage() {
    cat <<'HELP'
Usage:
  sudo bash packaging/recover-release.sh --list [TEST_TARGET_ROOT]
  sudo bash packaging/recover-release.sh --preview TRANSACTION_ID [TEST_TARGET_ROOT]
  sudo bash packaging/recover-release.sh --confirm TRANSACTION_ID [TEST_TARGET_ROOT]

Preview inspects one retained transaction without changing files. Confirm
restores the exact previous allowlisted ORM file set. TEST_TARGET_ROOT is only
for isolated root-owned Linux fixtures.
HELP
}

if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
[[ "$(id -u)" -eq 0 ]] || orm_die 'run signed-release recovery as root.'
[[ $# -ge 1 && $# -le 3 ]] || orm_die 'invalid recovery arguments; use --help.'
operation="$1"
transaction_id="${2:-}"
test_target_root="${3:-}"
if [[ "$operation" == --list ]]; then
    [[ $# -le 2 ]] || orm_die '--list accepts at most one test root.'
    test_target_root="${2:-}"
    transaction_id=''
elif [[ "$operation" == --preview || "$operation" == --confirm ]]; then
    [[ "$transaction_id" =~ ^transaction\.[A-Za-z0-9]+$ ]] || orm_die 'transaction ID must be an exact transaction.<suffix> directory name.'
else
    orm_die 'operation must be --list, --preview, or --confirm.'
fi
if [[ -n "$test_target_root" ]]; then
    [[ "$test_target_root" == /* && -d "$test_target_root" && ! -L "$test_target_root" \
        && "$(stat -c '%u:%a' -- "$test_target_root")" == 0:700 ]] \
        || orm_die 'test target root must be an existing root-owned directory with mode 0700.'
fi

orm_acquire_lifecycle_lock "$0" "$@"
[[ -n "$test_target_root" ]] || orm_require_root_and_platform

if [[ -n "$test_target_root" ]]; then
    state_root="${test_target_root%/}/var/cpanel/orm/updates"
    manifest="${test_target_root%/}${ORM_INSTALL_MANIFEST}"
else
    state_root=/var/cpanel/orm/updates
    manifest="$ORM_INSTALL_MANIFEST"
fi
[[ -d "$state_root" && ! -L "$state_root" && "$(stat -c '%u:%g:%a' "$state_root")" == 0:0:700 ]] \
    || orm_die 'the updater state directory is missing or unsafe.'

physical_target() {
    if [[ -n "$test_target_root" ]]; then printf '%s%s\n' "${test_target_root%/}" "$1"; else printf '%s\n' "$1"; fi
}

if [[ "$operation" == --list ]]; then
    find "$state_root" -mindepth 1 -maxdepth 1 -type d -name 'transaction.*' -printf '%f\n' | sort
    exit 0
fi

workspace="$state_root/$transaction_id"
[[ -d "$workspace" && ! -L "$workspace" && "$(stat -c '%u:%g:%a' "$workspace")" == 0:0:700 ]] \
    || orm_die 'the selected transaction is missing or not a root-owned mode-0700 directory.'
while IFS= read -r entry; do
    [[ ! -L "$entry" && "$(stat -c '%u' -- "$entry")" == 0 ]] \
        || orm_die 'transaction workspace contains a symlink or non-root-owned entry.'
    case "$(basename -- "$entry")" in
        stage|backup|preview.json|actions.txt|install-manifest.new|install-manifest.old|journal|.journal.*) ;;
        *) orm_die 'transaction workspace contains an unexpected entry; preserve it for administrator review.' ;;
    esac
done < <(find "$workspace" -mindepth 1 -maxdepth 1 -print)
for required in journal actions.txt install-manifest.old backup; do
    [[ -e "$workspace/$required" && ! -L "$workspace/$required" ]] \
        || orm_die "transaction material is missing or unsafe: $required"
done
[[ -f "$workspace/journal" && -f "$workspace/actions.txt" && -f "$workspace/install-manifest.old" \
    && -d "$workspace/backup" && "$(stat -c '%u:%g:%a' "$workspace/backup")" == 0:0:700 ]] \
    || orm_die 'transaction journal, action list, old manifest, or backup directory is unsafe.'
for file in journal actions.txt install-manifest.old; do
    [[ "$(stat -c '%u:%g:%a' "$workspace/$file")" == 0:0:600 ]] \
        || orm_die "transaction file must be root-owned mode 0600: $file"
done
[[ "$(stat -c '%s' "$workspace/journal")" -le 131072 && "$(stat -c '%s' "$workspace/actions.txt")" -le 65536 \
    && "$(stat -c '%s' "$workspace/install-manifest.old")" -le 65536 ]] \
    || orm_die 'transaction metadata exceeds its safe size limit.'

temporary="$(mktemp)"
candidate_manifest="$(mktemp)"
cleanup_recovery() { rm -f -- "$temporary" "$candidate_manifest"; }
trap cleanup_recovery EXIT

# Parse and bind the journal and action file to this build's fixed package map.
declare -A map_source=() map_target=() map_mode=() old_digest=() action=() source=() target=() mode=() candidate_digest=()
while IFS='|' read -r key src dst perm extra; do
    [[ "$key" =~ ^[a-z_]+$ && -z "${extra:-}" && -z "${map_target[$key]+x}" ]] || orm_die 'compiled package allowlist is invalid.'
    map_source[$key]="$src"; map_target[$key]="$dst"; map_mode[$key]="$perm"
done < <(orm_package_file_map)

head -n 1 -- "$workspace/journal" | grep -Fxq 'orm-update-transaction-v1' || orm_die 'journal format is unsupported.'
mapfile -t journal_lines <"$workspace/journal"
(( ${#journal_lines[@]} >= 6 )) || orm_die 'journal is truncated.'
installed_version="${journal_lines[1]#installed_version|}"
candidate_version="${journal_lines[2]#candidate_version|}"
artifact_digest="${journal_lines[3]#artifact_sha256|}"
phase="${journal_lines[4]#phase|}"
[[ "${journal_lines[1]}" == installed_version\|* && "${journal_lines[2]}" == candidate_version\|* \
    && "${journal_lines[3]}" == artifact_sha256\|* && "${journal_lines[4]}" == phase\|* ]] \
    || orm_die 'journal header fields are malformed.'
[[ "$installed_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ \
    && "$candidate_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ \
    && "$artifact_digest" =~ ^[a-f0-9]{64}$ ]] || orm_die 'journal release identity is malformed.'
case "$phase" in
    applying|manifest_written|rolling_back) ;;
    applied_*) [[ "${phase#applied_}" =~ ^[1-9][0-9]*$ ]] || orm_die 'journal phase is malformed.' ;;
    complete) orm_die 'transaction is already complete; recovery will not roll back a committed release.' ;;
    *) orm_die 'journal phase is unsupported; no files were changed.' ;;
esac
tail -n +6 -- "$workspace/journal" >"$temporary"
cmp -s -- "$temporary" "$workspace/actions.txt" || orm_die 'journal actions do not exactly match actions.txt.'

while IFS='|' read -r key op src dst perm digest extra || [[ -n "${key:-}" ]]; do
    [[ "$key" =~ ^[a-z_]+$ ]] || orm_die 'journal contains an invalid action key.'
    expected_source="${map_source[$key]:-}"
    expected_source="${expected_source#${ORM_REPO_ROOT}/}"
    [[ -n "$key" && -z "${extra:-}" && -n "${map_target[$key]+x}" \
        && -z "${action[$key]+x}" && "$op" =~ ^(add|adopt|replace|unchanged)$ \
        && "$src" == "$expected_source" && "$dst" == "${map_target[$key]}" \
        && "$perm" == "${map_mode[$key]}" && "$digest" =~ ^[a-f0-9]{64}$ ]] \
        || orm_die 'journal contains an unknown, duplicate, or malformed package action.'
    action[$key]="$op"; source[$key]="$src"; target[$key]="$dst"; mode[$key]="$perm"; candidate_digest[$key]="$digest"
done <"$workspace/actions.txt"
[[ ${#action[@]} -eq ${#map_target[@]} ]] || orm_die 'journal does not cover the complete compiled package allowlist.'
broker_files_changed=0
while IFS='|' read -r key op; do
    case "$key:$op" in
        broker_*:unchanged|broker_*:adopt|broker_bin:unchanged|broker_bin:adopt|broker_unit:unchanged|broker_unit:adopt|instance_unit:unchanged|instance_unit:adopt|metrics_service:unchanged|metrics_service:adopt|metrics_timer:unchanged|metrics_timer:adopt) ;;
        broker_*:*|broker_bin:*|broker_unit:*|instance_unit:*|metrics_service:*|metrics_timer:*) broker_files_changed=1 ;;
    esac
done <"$workspace/actions.txt"

# The old manifest is authoritative for prior content hashes. Validate its
# schema against the fixed map without requiring partially replaced targets to
# already match it.
[[ "$(head -n 1 "$workspace/install-manifest.old")" == orm-install-manifest-v3 ]] || orm_die 'old manifest format is unsupported.'
[[ "$(sed -n '2p' "$workspace/install-manifest.old")" == "version|$installed_version" ]] || orm_die 'old manifest version does not match the transaction.'
while IFS='|' read -r key perm digest dst extra || [[ -n "${key:-}" ]]; do
    [[ "$key" =~ ^[a-z_]+$ ]] || orm_die 'old manifest contains an invalid file key.'
    [[ -n "$key" && -z "${extra:-}" && -n "${map_target[$key]+x}" && -z "${old_digest[$key]+x}" \
        && "$perm" == "${map_mode[$key]}" && "$digest" =~ ^[a-f0-9]{64}$ && "$dst" == "${map_target[$key]}" ]] \
        || orm_die 'old manifest contains an invalid or duplicate file record.'
    old_digest[$key]="$digest"
done < <(tail -n +3 -- "$workspace/install-manifest.old")
[[ ${#old_digest[@]} -gt 0 ]] || orm_die 'old manifest has no managed files.'

while IFS='|' read -r key op src dst perm digest; do
    [[ "$key" != whm_appconfig ]] || {
        [[ ( "$op" == unchanged || "$op" == replace ) && -n "${old_digest[$key]+x}" ]] \
            || orm_die 'WHM AppConfig changes are outside signed-release recovery.'
        [[ "$(physical_target "$dst")" == "$ORM_APPCONFIG" || -n "$test_target_root" ]] \
            || orm_die 'WHM AppConfig target is not the fixed registration path.'
        appconfig_path="$(physical_target "$dst")"
        [[ -f "$appconfig_path" && ! -L "$appconfig_path" \
            && "$(sha256sum "$appconfig_path" | awk '{print $1}')" == "${old_digest[$key]}" ]] \
            || orm_die 'WHM AppConfig is not unchanged from the old manifest.'
        continue
    }
    case "$op" in
        add) [[ -z "${old_digest[$key]+x}" ]] || orm_die "add action conflicts with the old manifest: $key" ;;
        adopt) [[ -z "${old_digest[$key]+x}" ]] || orm_die "adopt action conflicts with the old manifest: $key" ;;
        replace|unchanged) [[ -n "${old_digest[$key]+x}" ]] || orm_die "action is missing from the old manifest: $key" ;;
    esac
    [[ "$op" != unchanged || "$digest" == "${old_digest[$key]}" ]] || orm_die "unchanged action differs from the old manifest: $key"
    physical="$(physical_target "$dst")"
    orm_safe_target_parent_chain "$physical" || orm_die "target parent chain is unsafe: $key"
    parent="$(dirname -- "$physical")"
    while [[ "$parent" != / ]]; do
        [[ -d "$parent" && ! -L "$parent" && "$(stat -c '%u' "$parent")" == 0 ]] \
            || orm_die "target parent is not a root-owned real directory: $key"
        parent="$(dirname -- "$parent")"
    done
    if [[ "$op" == replace ]]; then
        backup="$workspace/backup/$key"
        [[ -f "$backup" && ! -L "$backup" && "$(stat -c '%u:%g:%a' "$backup")" == "0:0:$perm" \
            && "$(sha256sum "$backup" | awk '{print $1}')" == "${old_digest[$key]}" ]] \
            || orm_die "replacement backup is missing, unsafe, or does not match the old manifest: $key"
        [[ -f "$physical" && ! -L "$physical" && "$(stat -c '%u:%a' "$physical")" == "0:$perm" ]] \
            || orm_die "replacement target is missing or unsafe: $key"
        current="$(sha256sum "$physical" | awk '{print $1}')"
        [[ "$current" == "${old_digest[$key]}" || "$current" == "$digest" ]] \
            || orm_die "replacement target has an unexpected digest; preserve it for administrator review: $key"
    elif [[ "$op" == add ]]; then
        if [[ -e "$physical" || -L "$physical" ]]; then
            [[ -f "$physical" && ! -L "$physical" && "$(stat -c '%u:%a' "$physical")" == "0:$perm" \
                && "$(sha256sum "$physical" | awk '{print $1}')" == "$digest" ]] \
                || orm_die "added target is not the exact candidate file; preserve it for administrator review: $key"
        fi
    elif [[ "$op" == adopt ]]; then
        [[ -f "$physical" && ! -L "$physical" && "$(stat -c '%u:%a' "$physical")" == "0:$perm" \
            && "$(sha256sum "$physical" | awk '{print $1}')" == "$digest" ]] \
            || orm_die "adopted target is not the exact candidate file; preserve it for administrator review: $key"
    else
        [[ -f "$physical" && ! -L "$physical" && "$(stat -c '%u:%a' "$physical")" == "0:$perm" \
            && "$(sha256sum "$physical" | awk '{print $1}')" == "${old_digest[$key]}" ]] \
            || orm_die "unchanged target no longer matches the old manifest: $key"
    fi
done <"$workspace/actions.txt"

backup_keys="$(find "$workspace/backup" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)"
expected_backup_keys="$(while IFS='|' read -r key op _; do
    if [[ "$op" == replace && "$key" != whm_appconfig ]]; then printf '%s\n' "$key"; else :; fi
done <"$workspace/actions.txt" | sort)"
[[ -z "$(find "$workspace/backup" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] || orm_die 'backup directory contains a non-regular or symlink entry.'
[[ "$backup_keys" == "$expected_backup_keys" ]] || orm_die 'backup directory has missing or unexpected entries.'

# Build the only acceptable post-update manifest from the journal and compare
# the installed one with either that value or the byte-identical old manifest.
{
    printf 'orm-install-manifest-v3\nversion|%s\n' "$candidate_version"
    while IFS='|' read -r key op src dst perm digest; do
        [[ "$key" != whm_appconfig ]] || digest="${old_digest[$key]}"
        printf '%s|%s|%s|%s\n' "$key" "$perm" "$digest" "$dst"
    done <"$workspace/actions.txt"
} >"$candidate_manifest"
chmod 0600 "$candidate_manifest"
old_manifest_hash="$(sha256sum "$workspace/install-manifest.old" | awk '{print $1}')"
current_manifest_hash=''
if [[ -f "$manifest" && ! -L "$manifest" && "$(stat -c '%u:%a' "$manifest")" == 0:600 ]]; then
    current_manifest_hash="$(sha256sum "$manifest" | awk '{print $1}')"
fi
candidate_manifest_hash="$(sha256sum "$candidate_manifest" | awk '{print $1}')"
[[ "$current_manifest_hash" == "$old_manifest_hash" || "$current_manifest_hash" == "$candidate_manifest_hash" ]] \
    || orm_die 'installed manifest is neither the exact old nor journal-derived candidate manifest.'
if (( broker_files_changed )) && [[ -z "$test_target_root" ]]; then
    [[ "$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)" != active ]] \
        || orm_die 'broker is active; recovery will not change broker or systemd files.'
fi

if [[ "$operation" == --preview ]]; then
    printf 'Validated rollback for %s: %s -> %s; phase=%s; managed files=%s. No files changed.\n' \
        "$transaction_id" "$candidate_version" "$installed_version" "$phase" "${#action[@]}"
    exit 0
fi
[[ "$operation" == --confirm ]] || orm_die 'expected --preview or --confirm.'
printf 'Confirmed rollback of %s: %s -> %s.\n' "$transaction_id" "$candidate_version" "$installed_version"

# Restore from verified backups in reverse package order. Each operation is
# digest-classified before it runs, so a second invocation safely resumes.
mapfile -t action_keys < <(awk -F'|' '$2 != "unchanged" && $2 != "adopt" && $1 != "whm_appconfig" { print $1 }' "$workspace/actions.txt")
for ((index=${#action_keys[@]}-1; index>=0; index--)); do
    key="${action_keys[$index]}"; op="${action[$key]}"; physical="$(physical_target "${target[$key]}")"
    orm_safe_target_parent_chain "$physical" || orm_die "target parent changed during recovery: $key"
    if [[ "$op" == add ]]; then
        if [[ -e "$physical" || -L "$physical" ]]; then
            [[ -f "$physical" && ! -L "$physical" && "$(sha256sum "$physical" | awk '{print $1}')" == "${candidate_digest[$key]}" ]] \
                || orm_die "added target changed during recovery: $key"
            rm -- "$physical"
        fi
    else
        current="$(sha256sum "$physical" | awk '{print $1}')"
        if [[ "$current" != "${old_digest[$key]}" ]]; then
            temp_file="$(mktemp "$(dirname -- "$physical")/.orm-recover.XXXXXXXX")"
            if ! cp -p -- "$workspace/backup/$key" "$temp_file" \
                || ! chown root:root "$temp_file" || ! chmod "${mode[$key]}" "$temp_file" \
                || ! mv -f -- "$temp_file" "$physical"; then
                rm -f -- "$temp_file"
                orm_die "could not atomically restore the old managed file: $key"
            fi
        fi
    fi
done

if (( broker_files_changed )) && [[ -z "$test_target_root" ]]; then
    "$ORM_SYSTEMCTL" daemon-reload || orm_die 'systemd could not reload restored ORM unit files; recovery material is retained.'
    [[ "$("$ORM_SYSTEMCTL" is-active orm-broker.service 2>/dev/null || true)" != active ]] \
        || orm_die 'broker became active during recovery; recovery material is retained for review.'
fi

if [[ "$current_manifest_hash" != "$old_manifest_hash" ]]; then
    manifest_parent="$(dirname -- "$manifest")"
    orm_safe_target_parent_chain "$manifest" || orm_die 'installed manifest parent changed during recovery.'
    temp_manifest="$(mktemp "$manifest_parent/.orm-recover-manifest.XXXXXXXX")"
    cp -p -- "$workspace/install-manifest.old" "$temp_manifest"
    chown root:root "$temp_manifest"; chmod 0600 "$temp_manifest"
    mv -f -- "$temp_manifest" "$manifest"
fi

# Verify every restored managed file using the saved v3 manifest and fixed map.
if [[ -z "$test_target_root" ]]; then
    orm_validate_install_manifest "$manifest" allow-known-subset || orm_die 'restored installation did not pass manifest validation; recovery material is retained.'
    orm_registration_state || orm_die 'WHM registration could not be verified after rollback; recovery material is retained.'
else
    while IFS='|' read -r key perm digest dst; do
        physical="$(physical_target "$dst")"
        [[ -f "$physical" && ! -L "$physical" && "$(stat -c '%u:%a' "$physical")" == "0:$perm" \
            && "$(sha256sum "$physical" | awk '{print $1}')" == "$digest" ]] \
            || orm_die "restored fixture file failed verification: $key"
    done < <(tail -n +3 "$workspace/install-manifest.old")
fi

audit_file="$state_root/update-audit.jsonl"
[[ ! -L "$audit_file" && ( ! -e "$audit_file" || -f "$audit_file" ) ]] || orm_die 'updater audit path is unsafe; recovery material is retained.'
if [[ ! -e "$audit_file" ]]; then (umask 077; : >"$audit_file"); fi
chown root:root "$audit_file"; chmod 0600 "$audit_file"
[[ "$(stat -c '%s' "$audit_file")" -le 1048576 ]] || orm_die 'updater audit log is full; recovery material is retained.'
if ! ORM_RECOVERY_TRANSACTION_ID="$transaction_id" "$ORM_PERL" -MJSON::PP -e '
    my ($path, $from, $to, $digest) = @ARGV;
    open my $fh, "<", $path or exit 2;
    while (my $line = <$fh>) {
        my $row = eval { JSON::PP->new->decode($line) };
        exit 0 if ref($row) eq "HASH" && ($row->{event}//"") eq "release.update"
            && ($row->{outcome}//"") eq "rolled_back" && ($row->{fromVersion}//"") eq $from
            && ($row->{toVersion}//"") eq $to && ($row->{artifactSha256}//"") eq $digest
            && ($row->{transactionId}//"") eq $ENV{ORM_RECOVERY_TRANSACTION_ID};
    }
    exit 1;
' "$audit_file" "$installed_version" "$candidate_version" "$artifact_digest"; then
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    record="{\"actor\":\"root\",\"artifactSha256\":\"$artifact_digest\",\"event\":\"release.update\",\"fromVersion\":\"$installed_version\",\"outcome\":\"rolled_back\",\"timestamp\":\"$timestamp\",\"toVersion\":\"$candidate_version\",\"transactionId\":\"$transaction_id\"}"$'\n'
    exec {audit_fd}>>"$audit_file"
    flock -x "$audit_fd"
    [[ "$(stat -c '%s' "$audit_file")" -le 1048576 ]] || {
        flock -u "$audit_fd"; exec {audit_fd}>&-
        orm_die 'updater audit log became full; recovery material is retained.'
    }
    printf '%s' "$record" >&"$audit_fd"
    flock -u "$audit_fd"
    exec {audit_fd}>&-
fi

rm -rf -- "$workspace"
printf 'Rollback verified and finalized for %s. The prior managed files and manifest are restored; account data, Redis/Valkey data, and backend policy were not touched.\n' "$transaction_id"
