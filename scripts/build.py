#!/usr/bin/env python3
"""Serialized builds and conservative cache retention for this checkout only."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from build_cache import Hold, cache_report, prune, safe_path, size_bytes

ROOT = Path(__file__).resolve().parents[1]
LEASE = "STILLHERE_BUILD_LEASE"
GIB = 1024 ** 3


def check_runtime():
    if sys.version_info < (3, 11):
        raise Hold("Python 3.11 or later is required for safe build maintenance.")


def load_policy(root):
    policy = json.loads((root / "scripts/build-policy.json").read_text())
    if policy.get("version") != 1:
        raise Hold("Unsupported build-policy version.")
    for key in ("cache_max_gib", "cache_inactive_days", "cache_grace_hours",
                "minimum_free_gib", "native_max_gib", "website_max_gib",
                "native_peak_growth_gb"):
        value = policy.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise Hold(f"{key} must be a finite positive number.")
    if policy["cache_grace_hours"] >= policy["cache_inactive_days"] * 24:
        raise Hold("Cache inactivity must be longer than the warm-cache grace period.")
    return policy


def state_dir(root):
    path = safe_path(root, root / "build/.maintenance")
    path.mkdir(parents=True, exist_ok=True)
    return path


def inherited(root, env):
    raw = env.get(LEASE)
    if not raw:
        return None
    try:
        token = json.loads(raw)
        fd = token["fd"]
        path = safe_path(root, root / "build/.maintenance/build.lock")
        actual, held = path.stat(), os.fstat(fd)
        if token["root"] != str(root) or (actual.st_dev, actual.st_ino) != (held.st_dev, held.st_ino):
            raise ValueError("different checkout or lock")
        if os.pread(fd, 4096, 0).decode() != token["nonce"]:
            raise ValueError("stale lock")
        probe = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return fd
            raise ValueError("lock is no longer held")
        finally:
            os.close(probe)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise Hold("Invalid inherited build lease; restart through scripts/build.py.") from error


@contextmanager
def lease(root, env):
    fd = inherited(root, env)
    if fd is not None:
        yield fd, False
        return
    path = state_dir(root) / "build.lock"
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Hold("Another build or cleanup owns this checkout. Reuse its result, then rerun if needed.") from error
        nonce = uuid.uuid4().hex
        os.ftruncate(fd, 0)
        os.pwrite(fd, nonce.encode(), 0)
        env[LEASE] = json.dumps(dict(root=str(root), fd=fd, nonce=nonce))
        yield fd, True
    finally:
        # Never unlink a lock: all callers must keep using the same inode.
        os.close(fd)


def diagnostic(message):
    try:
        print(message, file=sys.stderr)
    except (OSError, ValueError):
        pass


def record(root, event):
    try:
        path = safe_path(root, state_dir(root) / "events.jsonl")
        # Keep the current and one previous log, each at most about 1 MiB.
        if path.exists() and path.stat().st_size >= 1024 ** 2:
            previous = safe_path(root, path.with_suffix(".previous.jsonl"))
            os.replace(path, previous)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps(dict(at=time.time(), **event)) + "\n").encode())
        finally:
            os.close(fd)
    except (OSError, ValueError, Hold) as error:
        diagnostic(f"[build] Event log unavailable: {error}")


def output_report(root):
    return {name: size_bytes(safe_path(root, root / path)) for name, path in (
        ("native", ".build"), ("website", "website/target"),
        ("tool_builds", "website/var/cargo-tools/target"))}


def preflight(root, policy):
    free = shutil.disk_usage(root).free
    if free < policy["minimum_free_gib"] * GIB:
        raise Hold("Free disk space is below minimum_free_gib; run scripts/build.py report.")
    output = output_report(root)
    for name, amount in (("native", output["native"]),
                         ("website", output["website"] + output["tool_builds"])):
        if amount > policy[f"{name}_max_gib"] * GIB:
            raise Hold(f"{name} output exceeds its build-policy limit. Preview scripts/build.py clean; "
                       "keep products and evidence until their owner qualifies further cleanup.")


def child(command, env, fd, cwd):
    previous, pending, process = {}, [], None
    descriptors = {fd}
    if env.get("DISK_GUARD_RESERVATION"):
        try:
            reservation_fd = int(json.loads(env["DISK_GUARD_RESERVATION"])["fd"])
            os.fstat(reservation_fd)
            descriptors.add(reservation_fd)
        except (ValueError, KeyError, TypeError, OSError) as error:
            raise Hold("Invalid inherited Disk Guard reservation; no build started.") from error

    def forward(sig, _frame):
        if process is None:
            pending.append(sig)
        else:
            process.send_signal(sig)

    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, forward)
        process = subprocess.Popen(command, cwd=cwd, env=env, pass_fds=tuple(descriptors))
        for sig in pending:
            process.send_signal(sig)
        result = process.wait()
        return result if result >= 0 else 128 - result
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def swift_command(root, policy, arguments):
    # One scratch directory for every native route. Redirection would create
    # an unaccounted duplicate and change cleanup scope.
    if any(a.split("=", 1)[0] in ("--scratch-path", "--package-path") for a in arguments):
        raise Hold("Native paths are managed here; use this checkout's .build directory.")
    command = ["swift", arguments[0], "--package-path", str(root),
               "--scratch-path", str(root / ".build"), *arguments[1:]]
    guard = shutil.which("disk-guard")
    if guard and "--show-bin-path" not in arguments:
        paths = (root, Path(tempfile.gettempdir()), Path.home() / "Library/Caches",
                 Path.home() / "Library/org.swift.swiftpm", Path.home() / ".swiftpm")
        prefix = [guard, "run", "--budget-gb", str(policy["native_peak_growth_gb"])]
        for path in paths:
            prefix += ["--volume", str(path)]
        command = [*prefix, "--", *command]
    return command


def execute(root, policy, command, cwd, env):
    with lease(root, env) as (fd, owner):
        if owner:
            # Cleanup can free expired caches before capacity admission. Its
            # errors preserve files; actual build-capacity checks still apply.
            maintain(root, policy)
            preflight(root, policy)
        result = child(command, env, fd, cwd)
        if owner:
            record(root, dict(kind="build", executable=Path(command[0]).name, exit=result))
            if result == 0:
                maintain(root, policy)
            else:
                diagnostic("[build] Failed build output retained; post-build cleanup skipped.")
        return result


def maintain(root, policy):
    try:
        result = prune(root, policy)
        record(root, dict(kind="cleanup", **result))
        if result["removed_bytes"]:
            diagnostic(f"[build] Reclaimed {result['removed_bytes'] / GIB:.2f} GiB of disposable caches.")
        if result["held"]:
            diagnostic("[build] Some caches retained: " + "; ".join(result["held"]))
        return result
    except (OSError, ValueError, Hold, subprocess.SubprocessError) as error:
        diagnostic(f"[build] Cleanup held; files retained: {error}")
        return {"removed_bytes": 0, "removed": [], "held": [str(error)]}


def main():
    check_runtime()
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("report", help="Inspect sizes and the cache-retention plan without deleting.")
    clean = sub.add_parser("clean", help="Preview retention; --apply removes eligible caches only.")
    clean.add_argument("--apply", action="store_true")
    sub.add_parser("check-lease", help=argparse.SUPPRESS)
    swift = sub.add_parser("swift", help="Run Swift build, test or run with one scratch path.")
    swift.add_argument("arguments", nargs=argparse.REMAINDER)
    run = sub.add_parser("exec", help="Serialize a repository build script or command.")
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    policy = load_policy(ROOT)
    if args.mode == "check-lease":
        if inherited(ROOT, os.environ) is None:
            raise Hold("No inherited build lease.")
        return 0
    if args.mode in ("report", "clean") and not getattr(args, "apply", False):
        print(json.dumps(dict(root=str(ROOT), policy=policy, outputs=output_report(ROOT),
                              caches=cache_report(ROOT, policy)), indent=2))
        return 0
    env = dict(os.environ)
    if args.mode == "clean":
        with lease(ROOT, env):
            result = maintain(ROOT, policy)
        print(json.dumps(result, indent=2))
        return 75 if result["held"] else 0
    if args.mode == "swift":
        raw = args.arguments
        if not raw or raw[0] not in ("build", "test", "run"):
            raise Hold("Expected swift build, test, or run.")
        return execute(ROOT, policy, swift_command(ROOT, policy, raw), ROOT, env)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise Hold("No build command supplied.")
    return execute(ROOT, policy, command, Path.cwd(), env)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Hold, OSError, ValueError, subprocess.SubprocessError) as error:
        diagnostic(f"BUILD HOLD: {error}")
        sys.exit(75)
