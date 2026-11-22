#!/usr/bin/env python3
"""Exercise the live WHM report with a temporary synthetic partial snapshot.

Run as root on a disposable cPanel & WHM host from the exact ORM source tree:
  python3 tests/whm-live-partial-podman-coverage.py --confirm-live-operation

The check requires an inactive, disabled EA Podman sampler and no counter
baseline. It preserves any existing stale summary by hard-linking its original
inode in the private sampler directory, submits a root-owned synthetic
incomplete-scan summary through the authenticated WHM report flow, then removes
only the unchanged test file and restores the original inode and contents. A
forced kill or host failure cannot run cleanup; the original then remains at a
hidden root-private backup path and needs manual restore.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
import re
import secrets
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
CPANEL_ROOT = Path("/usr/local/cpanel")
ORM_ROOT = CPANEL_ROOT / "3rdparty" / "orm"
SNAPSHOT_ROOT = Path("/var/lib/orm-podman")
SNAPSHOT_PATH = SNAPSHOT_ROOT / "summary.json"
BASELINE_PATH = SNAPSHOT_ROOT / "counter-baseline.json"
REPORT_FORM = REPO_ROOT / "tests" / "whm-live-security-report-form.php"
CPANEL_PHP = CPANEL_ROOT / "3rdparty" / "bin" / "php"
MAX_COMMAND_OUTPUT = 32 * 1024
MAX_SNAPSHOT_BYTES = 4096
STALE_AFTER_SECONDS = 30 * 60
SUCCESS_MARKER = "Live WHM partial Podman report passed: authenticated SSO; synthetic incomplete-scan coverage rendered as unknown; audit event verified."

SOURCE_MATCHES = (
    (REPO_ROOT / "VERSION", ORM_ROOT / "VERSION"),
    (REPO_ROOT / "src" / "Orm" / "Security" / "WhmSecurityReport.php",
     ORM_ROOT / "src" / "Orm" / "Security" / "WhmSecurityReport.php"),
    (REPO_ROOT / "src" / "Orm" / "Cpanel" / "BrokerClient.php",
     ORM_ROOT / "src" / "Orm" / "Cpanel" / "BrokerClient.php"),
    (REPO_ROOT / "src" / "Orm" / "Broker" / "FleetInventory.pm",
     ORM_ROOT / "lib" / "Orm" / "Broker" / "FleetInventory.pm"),
    (REPO_ROOT / "src" / "Orm" / "Broker" / "PodmanMetricsCollector.pm",
     ORM_ROOT / "lib" / "Orm" / "Broker" / "PodmanMetricsCollector.pm"),
    (REPO_ROOT / "src" / "Orm" / "Security" / "WhmAuditLog.php",
     ORM_ROOT / "src" / "Orm" / "Security" / "WhmAuditLog.php"),
    (REPO_ROOT / "src" / "Orm" / "Security" / "WhmSecurityReportPolicyStore.php",
     ORM_ROOT / "src" / "Orm" / "Security" / "WhmSecurityReportPolicyStore.php"),
    (REPO_ROOT / "packaging" / "whm" / "cgi" / "addon_open_redis_manager.php",
     CPANEL_ROOT / "whostmgr" / "docroot" / "cgi" / "addon_open_redis_manager.php"),
)


class LiveCheckError(RuntimeError):
    """A sanitized precondition, command, or state assertion failed."""


class PreservedSnapshot:
    """Identity and content digest for a safely staged existing summary."""

    def __init__(self, backup: Path, info: os.stat_result, digest: bytes) -> None:
        self.backup = backup
        self.identity = (info.st_dev, info.st_ino)
        self.uid = info.st_uid
        self.gid = info.st_gid
        self.mode = stat.S_IMODE(info.st_mode)
        self.size = info.st_size
        self.mtime_ns = info.st_mtime_ns
        self.digest = digest


@contextmanager
def block_cleanup_signals():
    """Keep termination signals pending until a rollback has finished."""
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
                                           {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def run(argv: list[str], *, timeout: int = 8, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(argv, check=False, capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LiveCheckError("a required local command was unavailable or timed out") from error
    if len(result.stdout.encode("utf-8", "replace")) > MAX_COMMAND_OUTPUT \
            or len(result.stderr.encode("utf-8", "replace")) > MAX_COMMAND_OUTPUT:
        raise LiveCheckError("a required local command exceeded its bounded output limit")
    return result


def state(action: str, unit: str) -> str:
    result = run(["systemctl", action, unit])
    output = result.stdout.strip()
    allowed = {
        "is-active": {"active", "inactive", "failed", "activating", "deactivating", "unknown"},
        "is-enabled": {"enabled", "enabled-runtime", "disabled", "static", "indirect",
                       "masked", "generated", "transient", "not-found"},
    }
    if result.returncode not in (0, 1, 3, 4) or output not in allowed[action]:
        raise LiveCheckError("the EA Podman sampler state could not be verified")
    return output


def verify_source_match() -> None:
    if not REPORT_FORM.is_file() or not CPANEL_PHP.is_file() or not (CPANEL_ROOT / "bin" / "whmapi1").is_file():
        raise LiveCheckError("cPanel or the live report harness is unavailable")
    for source, installed in SOURCE_MATCHES:
        try:
            if not source.is_file() or not installed.is_file() \
                    or hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(installed.read_bytes()).digest():
                raise LiveCheckError("installed ORM report files did not match this source tree")
        except OSError as error:
            raise LiveCheckError("installed ORM report files could not be verified") from error


def partial_snapshot(sampled_at: int) -> dict[str, Any]:
    return {
        "backend_counts": {"redis": 1, "valkey": 0},
        "counter_window": {
            "auth_available": False,
            "max_auth_failures_delta": 0,
            "max_evictions_delta": 0,
            "max_operations_per_second": 0,
            "process_count": 0,
            "reason": "incomplete_scan",
            "sampled_at": sampled_at,
            "status": "unknown",
            "window_seconds": 0,
            "window_start_at": 0,
        },
        "discovered_count": 1,
        "metrics": {
            "connected_clients": 0,
            "evicted_keys": 0,
            "keyspace_hits": 0,
            "keyspace_misses": 0,
            "memory_used_bytes": 0,
            "total_commands_processed": 0,
        },
        "partial": True,
        "sampled_at": sampled_at,
        "sampled_backend_counts": {"redis": 1, "valkey": 0},
        "sampled_count": 1,
        "scan_complete": False,
        "unmeasured_count": 1,
        "unverified_account_count": 0,
        "reachable_count": 0,
        "skipped_count": 0,
        "success": True,
        "version": 2,
    }


def verify_snapshot_directory() -> None:
    try:
        directory = SNAPSHOT_ROOT.lstat()
        resolved = SNAPSHOT_ROOT.resolve(strict=True)
    except OSError as error:
        raise LiveCheckError("the existing Podman sampler directory is unavailable") from error
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != 0 \
            or stat.S_IMODE(directory.st_mode) != 0o700 or resolved != SNAPSHOT_ROOT:
        raise LiveCheckError("the Podman sampler directory has unexpected ownership or permissions")


def path_exists_without_following(path: Path) -> bool:
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError as error:
        raise LiveCheckError("the Podman sampler state could not be inspected safely") from error


def stage_existing_snapshot(*, allow_existing_stale: bool,
                            recovery_state: dict[str, Any]) -> PreservedSnapshot | None:
    """Temporarily move a stale summary out of the live pathname, preserving its inode."""
    verify_snapshot_directory()
    if path_exists_without_following(BASELINE_PATH):
        raise LiveCheckError("a Podman counter baseline exists; refusing to run the partial-coverage check")
    if not path_exists_without_following(SNAPSHOT_PATH):
        return None
    if not allow_existing_stale:
        raise LiveCheckError("an existing stale summary requires explicit replacement confirmation")

    backup: Path | None = None
    linked = False
    removed = False
    completed = False
    try:
        original = SNAPSHOT_PATH.lstat()
        if not stat.S_ISREG(original.st_mode) or original.st_uid != 0 \
                or original.st_nlink != 1 or stat.S_IMODE(original.st_mode) != 0o600 \
                or original.st_size > MAX_SNAPSHOT_BYTES \
                or time.time() - original.st_mtime < STALE_AFTER_SECONDS:
            raise LiveCheckError("the existing Podman summary is not a private stale regular file")
        original_payload = SNAPSHOT_PATH.read_bytes()
        if len(original_payload) != original.st_size:
            raise LiveCheckError("the existing Podman summary changed while being read")
        try:
            decoded = json.loads(original_payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise LiveCheckError("the existing Podman summary is not valid JSON") from error
        if not isinstance(decoded, dict):
            raise LiveCheckError("the existing Podman summary has an unexpected structure")
        digest = hashlib.sha256(original_payload).digest()

        for _ in range(3):
            backup = SNAPSHOT_ROOT / (".orm-live-partial-" + secrets.token_hex(12) + ".backup")
            linked = True
            try:
                os.link(SNAPSHOT_PATH, backup, follow_symlinks=False)
                break
            except FileExistsError:
                linked = False
                continue
        if not linked or backup is None:
            raise LiveCheckError("a private staging name could not be reserved safely")

        staged = backup.lstat()
        current = SNAPSHOT_PATH.lstat()
        if (staged.st_dev, staged.st_ino) != (original.st_dev, original.st_ino) \
                or (current.st_dev, current.st_ino) != (original.st_dev, original.st_ino) \
                or staged.st_nlink != 2 or current.st_nlink != 2 \
                or staged.st_uid != 0 or stat.S_IMODE(staged.st_mode) != 0o600 \
                or hashlib.sha256(backup.read_bytes()).digest() != digest:
            raise LiveCheckError("the existing Podman summary changed during staging")

        preserved = PreservedSnapshot(backup, original, digest)
        recovery_state["preserved_snapshot"] = preserved

        latest = SNAPSHOT_PATH.lstat()
        if (latest.st_dev, latest.st_ino) != (original.st_dev, original.st_ino) \
                or latest.st_nlink != 2 or hashlib.sha256(SNAPSHOT_PATH.read_bytes()).digest() != digest:
            raise LiveCheckError("the existing Podman summary changed before staging completed")
        removed = True
        SNAPSHOT_PATH.unlink()
        if path_exists_without_following(SNAPSHOT_PATH):
            raise LiveCheckError("the live Podman summary path did not clear safely")
        verify_preserved_snapshot(preserved, links=1)
        completed = True
        return preserved
    except OSError as error:
        raise LiveCheckError("the existing Podman summary could not be staged safely") from error
    finally:
        # On a setup failure, put the original inode back before returning.
        if linked and backup is not None and not completed:
            with block_cleanup_signals():
                try:
                    if removed and not path_exists_without_following(SNAPSHOT_PATH):
                        os.link(backup, SNAPSHOT_PATH, follow_symlinks=False)
                        restored = SNAPSHOT_PATH.lstat()
                        if (restored.st_dev, restored.st_ino) != (original.st_dev, original.st_ino):
                            raise LiveCheckError("staged Podman summary recovery found a different inode")
                    if path_exists_without_following(SNAPSHOT_PATH):
                        current = SNAPSHOT_PATH.lstat()
                        if (current.st_dev, current.st_ino) != (original.st_dev, original.st_ino):
                            raise LiveCheckError("staged Podman summary recovery found a conflicting entry")
                    backup_info = backup.lstat()
                    if (backup_info.st_dev, backup_info.st_ino) != (original.st_dev, original.st_ino) \
                            or hashlib.sha256(backup.read_bytes()).digest() != digest:
                        raise LiveCheckError("staged Podman summary recovery found changed original contents")
                    backup.unlink()
                except FileNotFoundError as error:
                    if removed:
                        raise LiveCheckError("staging lost the original Podman summary; manual recovery is required") from error
                except LiveCheckError:
                    raise
                except OSError as error:
                    raise LiveCheckError("staging failed and the original Podman summary needs manual recovery") from error


def verify_preserved_snapshot(snapshot: PreservedSnapshot, *, links: int) -> None:
    try:
        info = snapshot.backup.lstat()
        if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != snapshot.identity \
                or info.st_uid != snapshot.uid or info.st_gid != snapshot.gid \
                or stat.S_IMODE(info.st_mode) != snapshot.mode or info.st_nlink != links \
                or info.st_size != snapshot.size or info.st_mtime_ns != snapshot.mtime_ns \
                or hashlib.sha256(snapshot.backup.read_bytes()).digest() != snapshot.digest:
            raise LiveCheckError("the preserved Podman summary changed; refusing to alter it")
    except OSError as error:
        raise LiveCheckError("the preserved Podman summary could not be verified") from error


def restore_existing_snapshot(snapshot: PreservedSnapshot) -> None:
    if not path_exists_without_following(snapshot.backup):
        try:
            restored = SNAPSHOT_PATH.lstat()
            if (restored.st_dev, restored.st_ino) == snapshot.identity \
                    and restored.st_nlink == 1 and restored.st_uid == snapshot.uid \
                    and restored.st_gid == snapshot.gid \
                    and stat.S_IMODE(restored.st_mode) == snapshot.mode \
                    and restored.st_size == snapshot.size and restored.st_mtime_ns == snapshot.mtime_ns \
                    and hashlib.sha256(SNAPSHOT_PATH.read_bytes()).digest() == snapshot.digest:
                return
        except OSError as error:
            raise LiveCheckError("the original Podman summary could not be checked after interruption") from error
        raise LiveCheckError("the original Podman summary backup is missing; manual recovery is required")
    verify_preserved_snapshot(snapshot, links=1)
    if path_exists_without_following(SNAPSHOT_PATH):
        raise LiveCheckError("the live Podman summary path is occupied; refusing to overwrite it")
    try:
        os.link(snapshot.backup, SNAPSHOT_PATH, follow_symlinks=False)
        restored = SNAPSHOT_PATH.lstat()
        verify_preserved_snapshot(snapshot, links=2)
        if (restored.st_dev, restored.st_ino) != snapshot.identity:
            raise LiveCheckError("the original Podman summary inode was not restored")
        snapshot.backup.unlink()
        final = SNAPSHOT_PATH.lstat()
        if (final.st_dev, final.st_ino) != snapshot.identity or final.st_nlink != 1 \
                or final.st_uid != snapshot.uid or final.st_gid != snapshot.gid \
                or stat.S_IMODE(final.st_mode) != snapshot.mode or final.st_size != snapshot.size \
                or final.st_mtime_ns != snapshot.mtime_ns \
                or hashlib.sha256(SNAPSHOT_PATH.read_bytes()).digest() != snapshot.digest:
            raise LiveCheckError("the original Podman summary was restored with unexpected state")
    except LiveCheckError:
        raise
    except OSError as error:
        raise LiveCheckError("the original Podman summary could not be restored safely") from error


def create_snapshot(recovery_state: dict[str, Any]) -> tuple[tuple[int, int], bytes]:
    verify_snapshot_directory()
    if path_exists_without_following(SNAPSHOT_PATH) or path_exists_without_following(BASELINE_PATH):
        raise LiveCheckError("Podman snapshot state changed after preflight; refusing to replace it")

    payload = json.dumps(partial_snapshot(int(time.time())), sort_keys=True,
                         separators=(",", ":")).encode("utf-8")
    if len(payload) > MAX_SNAPSHOT_BYTES:
        raise LiveCheckError("the test snapshot exceeded its fixed size limit")
    descriptor: int | None = None
    created_identity: tuple[int, int] | None = None
    completed = False
    try:
        blocked_signals = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
        try:
            descriptor = os.open(SNAPSHOT_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | getattr(os, "O_NOFOLLOW", 0), 0o600)
            created = os.fstat(descriptor)
            created_identity = (created.st_dev, created.st_ino)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        if not stat.S_ISREG(created.st_mode) or created.st_uid != 0 or created.st_nlink != 1:
            raise LiveCheckError("the synthetic snapshot file could not be verified")
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        current = SNAPSHOT_PATH.lstat()
        if (current.st_dev, current.st_ino) != (created.st_dev, created.st_ino) \
                or not stat.S_ISREG(current.st_mode) or current.st_uid != 0 \
                or stat.S_IMODE(current.st_mode) != 0o600 or SNAPSHOT_PATH.read_bytes() != payload:
            raise LiveCheckError("the synthetic snapshot changed during creation")
        recovery_state["synthetic_snapshot"] = ((created.st_dev, created.st_ino), payload)
        completed = True
        return (created.st_dev, created.st_ino), payload
    except OSError as error:
        raise LiveCheckError("the synthetic Podman snapshot could not be created safely") from error
    finally:
        with block_cleanup_signals():
            if descriptor is not None:
                os.close(descriptor)
            if not completed and created_identity is not None:
                try:
                    current = SNAPSHOT_PATH.lstat()
                    if (current.st_dev, current.st_ino) != created_identity \
                            or not stat.S_ISREG(current.st_mode) or current.st_uid != 0:
                        raise LiveCheckError("failed snapshot creation left a changed entry; manual cleanup is required")
                    SNAPSHOT_PATH.unlink()
                except FileNotFoundError:
                    pass
                except LiveCheckError:
                    raise
                except OSError:
                    raise LiveCheckError("failed snapshot creation could not be cleaned up safely")


def remove_snapshot(identity: tuple[int, int], payload: bytes) -> None:
    try:
        current = SNAPSHOT_PATH.lstat()
        if not stat.S_ISREG(current.st_mode) or current.st_uid != 0 \
                or current.st_nlink != 1 or stat.S_IMODE(current.st_mode) != 0o600 \
                or (current.st_dev, current.st_ino) != identity or SNAPSHOT_PATH.read_bytes() != payload:
            raise LiveCheckError("the temporary snapshot changed; refusing to remove an unverified file")
        SNAPSHOT_PATH.unlink()
    except FileNotFoundError:
        return
    except OSError as error:
        raise LiveCheckError("the temporary Podman snapshot could not be removed safely") from error


def run_partial_report() -> None:
    env = os.environ.copy()
    env["ORM_LIVE_REQUIRE_PARTIAL_PODMAN_EVIDENCE"] = "1"
    env.pop("ORM_LIVE_REQUIRE_PODMAN_EVIDENCE", None)
    env.pop("ORM_LIVE_REQUIRE_VALKEY_EVIDENCE", None)
    result = run([str(CPANEL_PHP), str(REPORT_FORM), "--confirm-report-write"], timeout=90, env=env)
    if result.returncode != 0 or SUCCESS_MARKER not in result.stdout:
        finding = re.search(r"\bpartial_podman_findings=(yes|no)\b", result.stderr)
        suffix = f" (partial findings rendered: {finding.group(1)})" if finding else ""
        raise LiveCheckError("the authenticated WHM report did not render the expected partial unknown findings"
                             + suffix)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-live-operation", action="store_true",
                        help="confirm a temporary synthetic snapshot and one report-only audit event")
    parser.add_argument("--confirm-existing-stale-snapshot-replacement", action="store_true",
                        help="allow a stale summary to be staged briefly and restored with its original inode")
    args = parser.parse_args()
    if not args.confirm_live_operation:
        parser.error("pass --confirm-live-operation only on a disposable cPanel test host")
    if os.name != "posix" or not sys.platform.startswith("linux") or os.geteuid() != 0:
        print("Live partial Podman report check requires root on Linux.", file=sys.stderr)
        return 2
    if not (Path("/var/cpanel/users").is_dir() and (CPANEL_ROOT / "bin" / "whmapi1").is_file()):
        print("Live partial Podman report check requires cPanel & WHM.", file=sys.stderr)
        return 2

    interrupt_requested = False

    def interrupt(_signum: int, _frame: Any) -> None:
        nonlocal interrupt_requested
        interrupt_requested = True

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupt)

    recovery_state: dict[str, Any] = {}
    cleanup_ok = True
    outcome = False
    try:
        verify_source_match()
        if state("is-active", "orm-podman-metrics.timer") != "inactive" \
                or state("is-enabled", "orm-podman-metrics.timer") != "disabled" \
                or state("is-active", "orm-podman-metrics.service") != "inactive":
            raise LiveCheckError("the EA Podman sampler is enabled or active; refusing to inject test data")
        if interrupt_requested:
            raise LiveCheckError("the live report check was interrupted before staging")
        if path_exists_without_following(SNAPSHOT_PATH) and not args.confirm_existing_stale_snapshot_replacement:
            raise LiveCheckError("a stale summary exists; explicitly confirm that it may be restored after this check")
        stage_existing_snapshot(allow_existing_stale=args.confirm_existing_stale_snapshot_replacement,
                                recovery_state=recovery_state)
        if interrupt_requested:
            raise LiveCheckError("the live report check was interrupted; cleanup will be attempted")
        create_snapshot(recovery_state)
        if interrupt_requested:
            raise LiveCheckError("the live report check was interrupted; cleanup will be attempted")
        run_partial_report()
        if interrupt_requested:
            raise LiveCheckError("the live report check was interrupted; cleanup will be attempted")
        outcome = True
    except LiveCheckError as error:
        print(f"Live partial Podman report check failed: {error}.", file=sys.stderr)
    except Exception as error:  # Never echo paths, account data, report output, or host state.
        print(f"Live partial Podman report check failed ({type(error).__name__}).", file=sys.stderr)
    finally:
        synthetic = recovery_state.get("synthetic_snapshot")
        if isinstance(synthetic, tuple) and len(synthetic) == 2:
            try:
                remove_snapshot(synthetic[0], synthetic[1])
            except Exception:
                cleanup_ok = False
        preserved_snapshot = recovery_state.get("preserved_snapshot")
        if preserved_snapshot is not None:
            try:
                restore_existing_snapshot(preserved_snapshot)
            except Exception:
                cleanup_ok = False
        try:
            if path_exists_without_following(BASELINE_PATH):
                cleanup_ok = False
            if state("is-active", "orm-podman-metrics.timer") != "inactive" \
                    or state("is-enabled", "orm-podman-metrics.timer") != "disabled" \
                    or state("is-active", "orm-podman-metrics.service") != "inactive":
                cleanup_ok = False
        except Exception:
            cleanup_ok = False

    if not cleanup_ok:
        print("Live partial Podman report cleanup could not verify restored Podman sampler state; manual review is required.",
              file=sys.stderr)
        return 1
    if interrupt_requested:
        print("Live partial Podman report check was interrupted; cleanup completed and verified.", file=sys.stderr)
        return 1
    if not outcome:
        return 1
    print("Live WHM partial Podman report passed: authenticated report rendered a synthetic incomplete scan as unknown.")
    if recovery_state.get("preserved_snapshot") is None:
        print("The synthetic snapshot was removed; the EA Podman sampler remained inactive and disabled.")
    else:
        print("The synthetic snapshot was removed and the original stale summary was restored; the EA Podman sampler remained inactive and disabled.")
    print("The report-only run wrote its normal metadata audit event and consumed the one-minute report throttle.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
