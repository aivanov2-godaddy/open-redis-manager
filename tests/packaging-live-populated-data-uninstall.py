#!/usr/bin/env python3
"""Guarded live cPanel check for idempotent install and populated-data refusal.

Run as root on a disposable cPanel & WHM host from an exact ORM source tree:
  python3 tests/packaging-live-populated-data-uninstall.py --confirm-live-operation

The check requires one stopped ORM-managed test instance and an already-correct
account-create hook. It creates one small, uniquely named sentinel inside that
instance's existing data directory, verifies the package scripts leave all
captured state unchanged, and removes only that exact sentinel. It never starts
or stops a Redis/Valkey service or changes EA Podman state.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

if sys.platform.startswith("linux"):
    import pwd

REPO_ROOT = Path(__file__).resolve().parents[1]
LIBRARY = REPO_ROOT / "packaging" / "lib.sh"
INSTALL = REPO_ROOT / "packaging" / "install.sh"
UNINSTALL = REPO_ROOT / "packaging" / "uninstall.sh"
INSTANCE_ROOT = Path("/etc/orm-instances")
INSTANCE_DATA_ROOT = Path("/var/lib/orm-instances")
CPANEL_ORM_ROOT = Path("/usr/local/cpanel/3rdparty/orm")
CPANEL_USERS_ROOT = Path("/var/cpanel/users")
MAX_TREE_ENTRIES = 10_000
MAX_TREE_BYTES = 512 * 1024 * 1024
MAX_COMMAND_OUTPUT = 32 * 1024
SENTINEL_PREFIX = ".orm-live-uninstall-guard."
SENTINEL_CONTENT = b"ORM live uninstall refusal check; synthetic data only.\n"
REFUSAL_MARKER = "managed instance files exist; refusing uninstall to preserve their services, configuration, and data."
IDEMPOTENT_INSTALL_MARKER = "already matches this package; account-create hook registration is verified."


class LiveCheckError(RuntimeError):
    """A sanitized precondition, command, or state assertion failed."""


def run_command(argv: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LiveCheckError("a required local command was unavailable or timed out") from error
    if len(result.stdout.encode("utf-8", "replace")) > MAX_COMMAND_OUTPUT \
            or len(result.stderr.encode("utf-8", "replace")) > MAX_COMMAND_OUTPUT:
        raise LiveCheckError("a local command exceeded its bounded output limit")
    return result


def require_real_directory(path: Path, owner_uid: int, *, private: bool = False) -> os.stat_result:
    try:
        info = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise LiveCheckError("a required instance directory could not be verified") from error
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner_uid or resolved != path:
        raise LiveCheckError("an instance directory has an unexpected type, owner, or path")
    if private and (stat.S_IMODE(info.st_mode) & 0o022):
        raise LiveCheckError("an instance data directory is writable by group or other users")
    return info


def source_integrity_and_hook_preflight() -> None:
    script = r"""
source "$1" || exit 20
orm_installation_matches_current_package || exit 21
orm_account_create_hook_state || exit 22
orm_registration_state || exit 23
orm_appconfig_matches_package "$ORM_APPCONFIG" || exit 24
"""
    result = run_command(["bash", "-c", script, "orm-live-package-guard", str(LIBRARY)])
    if result.returncode != 0:
        raise LiveCheckError("installed ORM files, WHM registration, or hook state did not match this source")


def locate_stopped_instance() -> tuple[str, pwd.struct_passwd, Path]:
    if not INSTANCE_ROOT.is_dir() or INSTANCE_ROOT.is_symlink():
        raise LiveCheckError("the ORM metadata root is unavailable or unsafe")
    manifests: list[tuple[str, Path]] = []
    try:
        for item in INSTANCE_ROOT.iterdir():
            if item.name.startswith("."):
                continue
            if item.is_symlink() or not item.is_dir():
                continue
            manifest = item / "manifest.json"
            if manifest.is_file() and not manifest.is_symlink():
                manifests.append((item.name, manifest))
    except OSError as error:
        raise LiveCheckError("the ORM instance inventory could not be read safely") from error
    if len(manifests) != 1:
        raise LiveCheckError("the live check requires exactly one registered ORM test instance")

    account, manifest = manifests[0]
    if not account.isascii() or not account.replace("_", "a").replace("-", "a").isalnum() or len(account) > 16:
        raise LiveCheckError("the test instance identity is outside the supported account-name format")
    try:
        identity = pwd.getpwnam(account)
        manifest_data = json.loads(manifest.read_text(encoding="utf-8"))
    except (KeyError, OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LiveCheckError("the managed test instance identity or manifest could not be verified") from error
    if not isinstance(manifest_data, dict):
        raise LiveCheckError("the managed test instance manifest has an unexpected format")

    data_directory = INSTANCE_DATA_ROOT / account
    require_real_directory(INSTANCE_DATA_ROOT, 0)
    require_real_directory(data_directory, identity.pw_uid, private=True)
    manifest_stat = manifest.lstat()
    if not stat.S_ISREG(manifest_stat.st_mode) or manifest_stat.st_uid != 0:
        raise LiveCheckError("the managed test instance manifest has an unexpected type or owner")

    state = run_command(["systemctl", "is-active", f"orm-instance@{account}.service"])
    if state.returncode != 3 or state.stdout.strip() != "inactive":
        raise LiveCheckError("the managed test instance service must be verifiably stopped")
    return account, identity, data_directory


def tree_digest(root: Path) -> tuple[str, int, int]:
    """Hash a bounded lstat-only tree; never follow links or print paths."""
    digest = hashlib.sha256()
    entries = 0
    total_bytes = 0
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            children = sorted(directory.iterdir(), key=lambda item: os.fsencode(item.name))
        except OSError as error:
            raise LiveCheckError("an ORM state directory could not be read") from error
        for child in children:
            try:
                info = child.lstat()
                relative = os.fsencode(child.relative_to(root).as_posix())
            except OSError as error:
                raise LiveCheckError("an ORM state entry changed during inspection") from error
            entries += 1
            if entries > MAX_TREE_ENTRIES:
                raise LiveCheckError("an ORM state tree exceeded the entry safety limit")
            kind = stat.S_IFMT(info.st_mode)
            digest.update(relative + b"\0")
            digest.update(f"{kind:o}:{stat.S_IMODE(info.st_mode):o}:{info.st_uid}:{info.st_gid}:{info.st_size}\0".encode())
            if stat.S_ISDIR(info.st_mode):
                pending.append(child)
            elif stat.S_ISREG(info.st_mode):
                total_bytes += info.st_size
                if total_bytes > MAX_TREE_BYTES:
                    raise LiveCheckError("an ORM state tree exceeded the byte safety limit")
                file_digest = hashlib.sha256()
                try:
                    with child.open("rb") as stream:
                        opened = os.fstat(stream.fileno())
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            raise LiveCheckError("an ORM state file changed during inspection")
                        for block in iter(lambda: stream.read(1024 * 1024), b""):
                            file_digest.update(block)
                except OSError as error:
                    raise LiveCheckError("an ORM state file could not be read") from error
                digest.update(file_digest.digest())
            elif stat.S_ISLNK(info.st_mode):
                try:
                    digest.update(os.fsencode(os.readlink(child)))
                except OSError as error:
                    raise LiveCheckError("an ORM state link could not be read safely") from error
    return digest.hexdigest(), entries, total_bytes


def command_state(argv: list[str], allowed: set[str]) -> str:
    result = run_command(argv)
    value = result.stdout.strip()
    if result.returncode not in (0, 1, 3, 4) or value not in allowed:
        raise LiveCheckError("a service state could not be verified")
    return value


def system_state(instance_account: str) -> dict[str, str]:
    units = (
        "orm-broker.service",
        "orm-provider-events.timer",
        "orm-podman-metrics.timer",
        f"orm-instance@{instance_account}.service",
    )
    state: dict[str, str] = {}
    for unit in units:
        state[f"active:{unit}"] = command_state(
            ["systemctl", "is-active", unit], {"active", "inactive", "failed", "unknown"}
        )
        state[f"enabled:{unit}"] = command_state(
            ["systemctl", "is-enabled", unit],
            {"enabled", "enabled-runtime", "disabled", "static", "indirect", "masked", "generated", "transient", "not-found"},
        )
    return state


def snapshot(instance_account: str) -> dict[str, Any]:
    source_version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip()
    try:
        installed_version = (CPANEL_ORM_ROOT / "VERSION").read_text(encoding="utf-8").strip()
    except OSError as error:
        raise LiveCheckError("the installed ORM version could not be read") from error
    if source_version != installed_version:
        raise LiveCheckError("the installed ORM version differs from this source tree")

    source_integrity_and_hook_preflight()
    etc_digest, etc_entries, etc_bytes = tree_digest(INSTANCE_ROOT)
    data_digest, data_entries, data_bytes = tree_digest(INSTANCE_DATA_ROOT)
    return {
        "version": source_version,
        "etc_tree": (etc_digest, etc_entries, etc_bytes),
        "data_tree": (data_digest, data_entries, data_bytes),
        "services": system_state(instance_account),
    }


def create_sentinel(directory: Path, identity: pwd.struct_passwd) -> tuple[Path, tuple[int, int], str]:
    token = secrets.token_hex(12)
    sentinel = directory / f"{SENTINEL_PREFIX}{token}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    created_inode: tuple[int, int] | None = None
    try:
        descriptor = os.open(sentinel, flags, 0o600)
        try:
            created = os.fstat(descriptor)
            created_inode = (created.st_dev, created.st_ino)
            os.fchown(descriptor, identity.pw_uid, identity.pw_gid)
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb", closefd=False) as stream:
                stream.write(SENTINEL_CONTENT)
                stream.flush()
                os.fsync(stream.fileno())
            info = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        # The file may already exist if a later ownership/mode/write operation
        # failed. Remove it only when this process can still prove it is the
        # regular file created by the exclusive open above.
        try:
            info = sentinel.lstat()
            if created_inode == (info.st_dev, info.st_ino) and stat.S_ISREG(info.st_mode):
                sentinel.unlink()
        except OSError:
            pass
        raise LiveCheckError("the synthetic data sentinel could not be created safely") from error
    return sentinel, (info.st_dev, info.st_ino), hashlib.sha256(SENTINEL_CONTENT).hexdigest()


def verify_sentinel(
    sentinel: Path,
    identity: pwd.struct_passwd,
    inode: tuple[int, int],
    expected_digest: str,
) -> None:
    try:
        info = sentinel.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 \
                or info.st_uid != identity.pw_uid or info.st_gid != identity.pw_gid \
                or (info.st_dev, info.st_ino) != inode:
            raise LiveCheckError("the synthetic sentinel identity or permissions changed")
        content_digest = hashlib.sha256(sentinel.read_bytes()).hexdigest()
    except OSError as error:
        raise LiveCheckError("the synthetic sentinel could not be verified") from error
    if content_digest != expected_digest:
        raise LiveCheckError("the synthetic sentinel contents changed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--confirm-live-operation",
        action="store_true",
        help="confirm a root-only live check that briefly creates and removes one synthetic data file",
    )
    args = parser.parse_args()
    if not args.confirm_live_operation:
        parser.error("pass --confirm-live-operation only on a disposable cPanel test host")
    if os.name != "posix" or not sys.platform.startswith("linux") or os.geteuid() != 0:
        print("Live package data guard check requires root on Linux.", file=sys.stderr)
        return 2
    if not CPANEL_USERS_ROOT.is_dir() or not Path("/usr/local/cpanel/bin/whmapi1").is_file():
        print("Live package data guard check requires a cPanel & WHM host.", file=sys.stderr)
        return 2
    if not (LIBRARY.is_file() and INSTALL.is_file() and UNINSTALL.is_file()):
        print("Live package data guard check requires the ORM source package.", file=sys.stderr)
        return 2

    sentinel: Path | None = None
    sentinel_inode: tuple[int, int] | None = None
    sentinel_digest: str | None = None
    base_snapshot: dict[str, Any] | None = None
    expected_sentinel_snapshot: dict[str, Any] | None = None
    identity: pwd.struct_passwd | None = None
    test_account = ""
    outcome = "failed"
    cleanup_ok = True
    try:
        test_account, identity, data_directory = locate_stopped_instance()
        base_snapshot = snapshot(test_account)
        sentinel, sentinel_inode, sentinel_digest = create_sentinel(data_directory, identity)
        verify_sentinel(sentinel, identity, sentinel_inode, sentinel_digest)
        expected_sentinel_snapshot = snapshot(test_account)

        install_result = run_command(["bash", str(INSTALL)], timeout=90)
        if install_result.returncode != 0 or IDEMPOTENT_INSTALL_MARKER not in install_result.stdout:
            raise LiveCheckError("the exact-source install did not take its idempotent path")
        if snapshot(test_account) != expected_sentinel_snapshot:
            raise LiveCheckError("idempotent install changed captured instance or service state")

        uninstall_result = run_command(["bash", str(UNINSTALL)], timeout=90)
        if uninstall_result.returncode == 0 or REFUSAL_MARKER not in uninstall_result.stderr + uninstall_result.stdout:
            raise LiveCheckError("uninstall did not report the expected managed-data refusal")
        verify_sentinel(sentinel, identity, sentinel_inode, sentinel_digest)
        if snapshot(test_account) != expected_sentinel_snapshot:
            raise LiveCheckError("uninstall refusal changed captured instance, registration, hook, or service state")
        outcome = "passed"
    except LiveCheckError as error:
        print(f"Live package data guard check failed: {error}.", file=sys.stderr)
    except Exception as error:  # Never echo raw host paths, account data, or command output.
        print(f"Live package data guard check failed ({type(error).__name__}).", file=sys.stderr)
    finally:
        if sentinel is not None and identity is not None and sentinel_inode is not None and sentinel_digest is not None:
            try:
                verify_sentinel(sentinel, identity, sentinel_inode, sentinel_digest)
                sentinel.unlink()
            except Exception:
                cleanup_ok = False
        if base_snapshot is not None and test_account:
            try:
                if snapshot(test_account) != base_snapshot:
                    cleanup_ok = False
            except Exception:
                cleanup_ok = False

    if not cleanup_ok:
        print("Live package data guard cleanup or original-state verification failed; manual review is required.", file=sys.stderr)
        return 1
    if outcome != "passed":
        return 1
    print("Live cPanel package lifecycle passed: exact-source install was idempotent; populated-data uninstall refused before changing captured state.")
    print("The test-owned synthetic sentinel was removed and original instance metadata/data tree state was restored.")
    print("This validates filesystem-entry preservation, not Redis keyspace persistence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
