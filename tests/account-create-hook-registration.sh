#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/packaging/lib.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/orm-account-hook.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

ORM_MANAGE_HOOKS="$test_root/manage_hooks"
ORM_ACCOUNT_CREATE_HOOK="$(command -v bash)"
export ORM_MANAGE_HOOKS ORM_ACCOUNT_CREATE_HOOK
cat >"$ORM_MANAGE_HOOKS" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    list)
        if [[ -f "$ORM_HOOK_REGISTRY" ]]; then
            printf 'Whostmgr:\n   Accounts::Create:\n      stage: post\n      exectype: script\n      hook: %s --run\n' "$(<"$ORM_HOOK_REGISTRY")"
        else
            printf 'Whostmgr:\n'
        fi
        ;;
    add)
        [[ "$2" == script && "$3" == "$ORM_ACCOUNT_CREATE_HOOK" ]]
        [[ " $* " == *' --manual '* && " $* " == *' --category Whostmgr '* \
            && " $* " == *' --event Accounts::Create '* && " $* " == *' --stage post '* \
            && " $* " == *' --action=--run '* ]]
        printf '%s\n' "$ORM_ACCOUNT_CREATE_HOOK" >"$ORM_HOOK_REGISTRY"
        [[ "${ORM_FAIL_ADD_AFTER_WRITE:-0}" != 1 ]]
        ;;
    delete)
        [[ "$2" == script && "$3" == "$ORM_ACCOUNT_CREATE_HOOK" ]]
        [[ " $* " == *' --manual '* && " $* " == *' --category Whostmgr '* \
            && " $* " == *' --event Accounts::Create '* && " $* " == *' --stage post '* \
            && " $* " == *' --action=--run '* ]]
        rm -f -- "$ORM_HOOK_REGISTRY"
        [[ "${ORM_FAIL_DELETE_AFTER_REMOVE:-0}" != 1 ]]
        ;;
    *) exit 2 ;;
esac
SH
chmod 0755 "$ORM_MANAGE_HOOKS"
export ORM_HOOK_REGISTRY="$test_root/registry"

orm_ensure_account_create_hook
[[ "$ORM_ACCOUNT_HOOK_ADDED" -eq 1 ]]
orm_account_create_hook_state
ORM_ACCOUNT_HOOK_ADDED=0
orm_ensure_account_create_hook
[[ "$ORM_ACCOUNT_HOOK_ADDED" -eq 0 ]]
orm_remove_account_create_hook
[[ "$ORM_ACCOUNT_HOOK_REMOVED" -eq 1 ]]
state=0
orm_account_create_hook_state || state=$?
[[ "$state" -eq 1 ]]
ORM_ACCOUNT_HOOK_ADDED=0
orm_ensure_account_create_hook
[[ "$ORM_ACCOUNT_HOOK_ADDED" -eq 1 ]]
rm -f -- "$ORM_HOOK_REGISTRY"
ORM_ACCOUNT_HOOK_ADDED=0
export ORM_FAIL_ADD_AFTER_WRITE=1
if orm_ensure_account_create_hook; then
    printf 'partial hook registration failure was incorrectly reported as success.\n' >&2
    exit 1
fi
unset ORM_FAIL_ADD_AFTER_WRITE
[[ "$ORM_ACCOUNT_HOOK_ADDED" -eq 1 ]]
orm_remove_account_create_hook
[[ "$ORM_ACCOUNT_HOOK_REMOVED" -eq 1 ]]

ORM_ACCOUNT_HOOK_ADDED=0
orm_ensure_account_create_hook
export ORM_FAIL_DELETE_AFTER_REMOVE=1
orm_remove_account_create_hook
unset ORM_FAIL_DELETE_AFTER_REMOVE
[[ "$ORM_ACCOUNT_HOOK_REMOVED" -eq 1 ]]
state=0
orm_account_create_hook_state || state=$?
[[ "$state" -eq 1 ]]
ORM_ACCOUNT_HOOK_ADDED=0
orm_ensure_account_create_hook
[[ "$ORM_ACCOUNT_HOOK_ADDED" -eq 1 ]]

printf 'Account create hook registration checks passed.\n'
