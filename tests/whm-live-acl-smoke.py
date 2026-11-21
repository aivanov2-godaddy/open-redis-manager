#!/usr/bin/env python3
"""Exercise the installed WHM plugin denial path with a disposable reseller.

Run as root on a disposable cPanel & WHM host. The helper creates one
domainless reseller, removes its ``all`` ACL if present, opens a temporary WHM
SSO session, checks the plugin returns HTTP 403, and removes the reseller in a
``finally`` block. It does not submit a form or run a Redis/Valkey operation.
Account names, SSO URLs, cookies, API output, and response bodies stay in
memory and are never printed or written to disk.
"""

from __future__ import annotations

import argparse
import hashlib
import http.cookiejar
import json
import os
import pwd
import re
import secrets
import ssl
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing

CPANEL_ROOT = "/usr/local/cpanel"
WHMAPI1 = f"{CPANEL_ROOT}/bin/whmapi1"
CPANEL_PHP = f"{CPANEL_ROOT}/3rdparty/bin/php"
WHM_CGI = f"{CPANEL_ROOT}/whostmgr/docroot/cgi/addon_open_redis_manager.php"
WHM_ACL = f"{CPANEL_ROOT}/3rdparty/orm/src/Orm/Security/WhmAcl.php"
RESELLERS_FILE = "/var/cpanel/resellers"
USERNAME = re.compile(r"\A[a-zA-Z0-9_-]{1,16}\Z")
SESSION_PATH = re.compile(r"\A(/cpsess[0-9]{10})/login/?\Z")
SHA256 = re.compile(r"\A[a-f0-9]{64}\Z")
MAX_PAGE_BYTES = 256 * 1024
TIMEOUT_SECONDS = 30


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def api(*arguments: str) -> dict:
    result = subprocess.run(
        [WHMAPI1, "--output=json", *arguments],
        capture_output=True,
        text=True,
        timeout=TIMEOUT_SECONDS,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("whm-api-failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("whm-api-response-invalid") from error
    if not isinstance(payload, dict):
        raise RuntimeError("whm-api-response-invalid")
    return payload


def api_succeeded(payload: dict) -> bool:
    return payload.get("metadata", {}).get("result") == 1


def account_users() -> set[str]:
    payload = api("listaccts")
    if not api_succeeded(payload):
        raise RuntimeError("account-list-failed")
    accounts = payload.get("data", {}).get("acct")
    if not isinstance(accounts, list):
        raise RuntimeError("account-list-invalid")
    users = [account.get("user") for account in accounts if isinstance(account, dict)]
    if len(users) != len(accounts) or any(not isinstance(user, str) or USERNAME.fullmatch(user) is None for user in users):
        raise RuntimeError("account-list-invalid")
    if len(users) != len(set(users)):
        raise RuntimeError("account-list-invalid")
    return set(users)


def reseller_acls() -> dict[str, frozenset[str]]:
    try:
        metadata = os.lstat(RESELLERS_FILE)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or os.path.islink(RESELLERS_FILE)
            or metadata.st_uid != 0
            or metadata.st_size > 4_194_304
        ):
            raise RuntimeError("reseller-file-unsafe")
        with open(RESELLERS_FILE, "r", encoding="utf-8") as handle:
            lines = handle.read(4_194_305).splitlines()
    except OSError as error:
        raise RuntimeError("reseller-file-unavailable") from error
    result: dict[str, frozenset[str]] = {}
    for line in lines:
        user, separator, permissions = line.partition(":")
        if not separator:
            continue
        if USERNAME.fullmatch(user) is None or user in result:
            raise RuntimeError("reseller-file-invalid")
        result[user] = frozenset(value.strip() for value in permissions.split(",") if value.strip())
    return result


def create_reseller_username(existing: set[str]) -> str:
    for _ in range(10):
        username = "ormacl" + secrets.token_hex(3)
        try:
            pwd.getpwnam(username)
        except KeyError:
            if username not in existing:
                return username
    raise RuntimeError("temporary-username-unavailable")


def installed_acl_denies(username: str) -> bool:
    environment = os.environ.copy()
    environment["ORM_WH_ACL_SMOKE_USER"] = username
    result = subprocess.run(
        [
            CPANEL_PHP,
            "-r",
            "require '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAcl.php'; "
            "echo \\Orm\\Security\\WhmAcl::allowsAdministrativeAccess(getenv('ORM_WH_ACL_SMOKE_USER')) "
            "? 'allowed' : 'denied';",
        ],
        capture_output=True,
        text=True,
        timeout=TIMEOUT_SECONDS,
        check=False,
        env=environment,
    )
    return result.returncode == 0 and result.stdout == "denied"


def validate_url(url: str, expected_host: str | None = None, prefix: str | None = None) -> urllib.parse.SplitResult:
    parts = urllib.parse.urlsplit(url)
    if (parts.scheme != "https" or not parts.hostname or parts.port != 2087
        or parts.username is not None or parts.password is not None or parts.fragment
        or (expected_host is not None and parts.hostname != expected_host)
        or (prefix is not None and not parts.path.startswith(prefix + "/"))):
        raise RuntimeError("whm-session-url-invalid")
    if re.fullmatch(r"[A-Za-z0-9.-]{1,253}", parts.hostname) is None:
        raise RuntimeError("whm-session-url-invalid")
    return parts


def open_same_session(
    opener: urllib.request.OpenerDirector,
    url: str,
    host: str,
    prefix: str,
) -> tuple[int, str]:
    current = url
    for _ in range(5):
        validate_url(current, host, prefix)
        try:
            response = opener.open(current, timeout=TIMEOUT_SECONDS)
        except urllib.error.HTTPError as error:
            response = error
        with closing(response):
            body = response.read(MAX_PAGE_BYTES + 1)
            if len(body) > MAX_PAGE_BYTES:
                raise RuntimeError("whm-page-too-large")
            status = response.code
            location = response.headers.get("Location")
        if status not in {301, 302, 303, 307, 308}:
            return status, body.decode("utf-8", "replace")
        if not isinstance(location, str) or not location:
            raise RuntimeError("whm-redirect-invalid")
        current = urllib.parse.urljoin(current, location)
    raise RuntimeError("whm-redirect-limit")


def run(expected_cgi_hash: str, expected_acl_hash: str) -> int:
    if os.geteuid() != 0 or sys.platform != "linux":
        raise RuntimeError("root-linux-required")
    for path, expected in ((WHM_CGI, expected_cgi_hash), (WHM_ACL, expected_acl_hash)):
        if SHA256.fullmatch(expected) is None:
            raise RuntimeError("expected-hash-invalid")
        try:
            digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        except OSError as error:
            raise RuntimeError("installed-source-unavailable") from error
        if digest != expected:
            raise RuntimeError("installed-source-mismatch")

    original_users = account_users()
    original_resellers = reseller_acls()
    username = create_reseller_username(original_users)
    created = False
    denial_verified = False
    cleanup_verified = False
    temporary_home: str | None = None
    try:
        try:
            creation = api(
                "createacct",
                f"username={username}",
                "reseller=1",
                "reseller_without_domain=1",
                "showpass=n",
            )
            created = api_succeeded(creation)
        except RuntimeError:
            try:
                pwd.getpwnam(username)
                created = True
            except KeyError:
                created = username in account_users() or username in reseller_acls()
            raise
        current_users = account_users()
        created = created or username in current_users
        if not api_succeeded(creation):
            raise RuntimeError("temporary-reseller-create-failed")
        if not original_users.issubset(current_users) or current_users - original_users not in (set(), {username}):
            raise RuntimeError("temporary-reseller-account-state-invalid")
        try:
            temporary_home = pwd.getpwnam(username).pw_dir
        except KeyError as error:
            raise RuntimeError("temporary-reseller-account-state-invalid") from error
        acl = reseller_acls().get(username)
        if acl is None:
            raise RuntimeError("temporary-reseller-acl-missing")
        if "all" in acl:
            changed = api("setreseller", f"reseller={username}", "acl-all=")
            if not api_succeeded(changed):
                raise RuntimeError("temporary-reseller-acl-restrict-failed")
            acl = reseller_acls().get(username)
        if acl is None or "all" in acl:
            raise RuntimeError("temporary-reseller-still-root-authorized")
        helper_denied = installed_acl_denies(username)
        if not helper_denied:
            raise RuntimeError("installed-whm-acl-helper-did-not-deny")

        session = api("create_user_session", f"user={username}", "service=whostmgrd")
        if not api_succeeded(session):
            raise RuntimeError("restricted-whm-sso-unavailable")
        sso_url = session.get("data", {}).get("url")
        if not isinstance(sso_url, str):
            raise RuntimeError("restricted-whm-sso-invalid")
        sso = validate_url(sso_url)
        match = SESSION_PATH.fullmatch(sso.path)
        if match is None or not sso.query:
            raise RuntimeError("restricted-whm-sso-invalid")
        prefix = match.group(1)

        cookies = http.cookiejar.CookieJar()
        tls_context = ssl._create_unverified_context()
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cookies),
            urllib.request.HTTPSHandler(context=tls_context),
            NoRedirect(),
        )
        login_status, _ = open_same_session(opener, sso_url, sso.hostname, prefix)
        target = f"https://{sso.hostname}:2087{prefix}/cgi/addon_open_redis_manager.php"
        status, body = open_same_session(opener, target, sso.hostname, prefix)
        denial_verified = (
            status in {401, 403}
            and (status == 401 or "Access denied. This page requires root-level WHM access." in body)
            and "Live backend discovery from the authenticated WHM session." not in body
            and "Generate report-only review" not in body
        )
        if not denial_verified:
            print(
                "Restricted page evidence: "
                f"login_status={login_status}, http_status={status}, "
                f"whm_denied={str(status in {401, 403}).lower()}, "
                f"denial_message={str('Access denied. This page requires root-level WHM access.' in body).lower()}, "
                f"root_discovery_hidden={str('Live backend discovery from the authenticated WHM session.' not in body).lower()}, "
                f"root_report_action_hidden={str('Generate report-only review' not in body).lower()}, "
                f"installed_acl_helper_denied={str(helper_denied).lower()}."
            )
            raise RuntimeError("restricted-whm-page-denial-not-proven")
    finally:
        if created:
            try:
                api("removeacct", f"user={username}")
            except (RuntimeError, subprocess.SubprocessError):
                pass
            current_users = account_users()
            current_resellers = reseller_acls()
            try:
                pwd.getpwnam(username)
                temporary_os_user_exists = True
            except KeyError:
                temporary_os_user_exists = False
            cleanup_verified = (
                username not in current_users
                and not temporary_os_user_exists
                and current_users == original_users
                and {user: acl for user, acl in current_resellers.items() if user != username} == original_resellers
                and (temporary_home is None or not os.path.lexists(temporary_home))
            )
        else:
            cleanup_verified = account_users() == original_users and reseller_acls() == original_resellers

    if not cleanup_verified:
        raise RuntimeError("temporary-reseller-cleanup-failed")
    if not denial_verified:
        raise RuntimeError("restricted-whm-page-denial-not-proven")
    print(
        "Current-source WHM restricted-reseller checks passed "
        f"(SSO HTTP {login_status}; plugin HTTP {status}; "
        "installed ACL helper denied; root content hidden)."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-cgi-sha256", required=True)
    parser.add_argument("--expected-acl-sha256", required=True)
    args = parser.parse_args()
    try:
        return run(args.expected_cgi_sha256, args.expected_acl_sha256)
    except Exception as error:
        reason = str(error)
        allowed = {
            "root-linux-required", "expected-hash-invalid", "installed-source-unavailable",
            "installed-source-mismatch", "whm-api-failed", "whm-api-response-invalid",
            "account-list-failed", "account-list-invalid", "reseller-file-unsafe",
            "reseller-file-unavailable", "reseller-file-invalid", "temporary-username-unavailable",
            "temporary-reseller-create-failed", "temporary-reseller-account-state-invalid",
            "temporary-reseller-acl-missing", "temporary-reseller-acl-restrict-failed",
            "temporary-reseller-still-root-authorized", "restricted-whm-sso-unavailable",
            "restricted-whm-sso-invalid", "whm-session-url-invalid", "whm-page-too-large",
            "whm-redirect-invalid", "whm-redirect-limit", "restricted-whm-page-denial-not-proven",
            "temporary-reseller-cleanup-failed", "installed-whm-acl-helper-did-not-deny",
        }
        print(f"Live WHM ACL smoke failed ({reason if reason in allowed else 'unexpected-error'}).")
        return 1


if __name__ == "__main__":
    sys.exit(main())
