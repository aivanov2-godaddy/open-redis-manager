#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || { printf 'release apply job integration tests must run as root.\n' >&2; exit 1; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_root=/var/cpanel/orm
package_root=/usr/local/cpanel/3rdparty/orm

[[ ! -e /var/cpanel && ! -L /var/cpanel ]] || {
    printf 'refusing to use an existing /var/cpanel tree in the job integration test.\n' >&2
    exit 1
}
[[ ! -e /usr/local/cpanel && ! -L /usr/local/cpanel ]] || {
    printf 'refusing to use an existing /usr/local/cpanel tree in the job integration test.\n' >&2
    exit 1
}
[[ -x /usr/bin/systemd-run && -x /usr/bin/timeout && -x /usr/bin/perl ]] || {
    printf 'the test runner is missing systemd-run, timeout, or Perl.\n' >&2
    exit 1
}

cleanup() {
    [[ ! -d /var/cpanel || -L /var/cpanel ]] || rm -rf -- /var/cpanel
    [[ ! -d /usr/local/cpanel || -L /usr/local/cpanel ]] || rm -rf -- /usr/local/cpanel
}
trap cleanup EXIT

mkdir -m 0755 /var/cpanel /usr/local/cpanel
mkdir -m 0755 /usr/local/cpanel/3rdparty
install -d -o root -g root -m 0700 "$state_root/updates/jobs"
install -D -o root -g root -m 0755 "$repo_root/bin/orm-update-worker.pl" \
    "$package_root/bin/orm-update-worker.pl"
ORM_TEST_FIXED_QUEUE=1 php "$repo_root/tests/release-apply-job.php"
