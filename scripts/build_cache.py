"""Only named compiler caches are eligible; products and evidence stay outside."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time

GIB = 1024 ** 3


class Hold(Exception):
    pass


def safe_path(root, path):
    """Reject redirects even when a symlink happens to resolve inside the repo."""
    root = root.resolve()
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise Hold(f"Path escapes checkout: {path}") from error
    if ".." in relative.parts or not relative.parts:
        raise Hold(f"Unsafe output path: {path}")
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise Hold(f"Symlinked output retained: {current}")
    return path


def size_bytes(path):
    if not path.exists():
        return 0
    result = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise Hold(f"Cannot measure output: {path}")
    return int(result.stdout.split()[0]) * 1024


def swift_lock(root):
    # SwiftPM's .build/.lock contains a PID, not the kernel lock. TSCBasic
    # FileLock.prepareLock derives this name in the process's temp directory.
    # https://github.com/swiftlang/swift-tools-support-core/blob/main/Sources/TSCBasic/Lock.swift
    name = str(root.resolve() / ".build").replace("/", "_").replace(":", "_") + ".lock"
    encoded = name.encode()[-255:]
    while True:
        try:
            name = encoded.decode()
            break
        except UnicodeDecodeError:
            encoded = encoded[1:]
    return Path(tempfile.gettempdir()).resolve() / name


def cache_roots(root):
    # Fixed paths, never a user-supplied removal glob. Neither Swift Products,
    # Cargo deps/build/site, installed tools, build/, nor dist/ are candidates.
    native = root / ".build"
    for name in ("ModuleCache.noindex", "SDKExplicitPrecompiledModules", "SDKStatCaches.noindex"):
        path = safe_path(root, native / "out" / name)
        if path.is_dir():
            yield path, "swift", native, [swift_lock(root)]
    if native.is_dir():
        for triple in native.iterdir():
            if triple.is_symlink() or not triple.is_dir() or triple.name == "out":
                continue
            for profile in ("debug", "release"):
                path = safe_path(root, triple / profile / "ModuleCache")
                if path.is_dir():
                    yield path, "swift", native, [swift_lock(root)]
    for relative in ("website/target", "website/var/cargo-tools/target"):
        target = safe_path(root, root / relative)
        if not target.is_dir():
            continue
        # Cargo profile layouts, including Leptos' target/front subtree.
        bases = [target]
        bases += [p for p in target.iterdir() if p.is_dir() and not p.is_symlink()
                  and (p.name == "front" or re.fullmatch(r"[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}", p.name))]
        front = target / "front"
        if front.is_dir() and not front.is_symlink():
            bases += [p for p in front.iterdir() if p.is_dir() and not p.is_symlink()
                      and re.fullmatch(r"[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}", p.name)]
        for base in bases:
            for profile in ("debug", "release"):
                parent = safe_path(root, base / profile)
                path = safe_path(root, parent / "incremental")
                if path.is_dir():
                    locks = [parent / name for name in (".cargo-lock", ".cargo-build-lock", ".cargo-artifact-lock")]
                    yield path, "rust", target, locks


def known_file(path, category):
    if category == "swift":
        return path.suffix in (".pcm", ".swiftmodule", ".swiftdoc", ".swiftsourceinfo", ".sdkstatcache")
    return path.name in ("dep-graph.bin", "query-cache.bin", "work-products.bin", "thin-lto-past-keys.bin") or path.suffix in (".o", ".bc", ".rmeta") or bool(re.fullmatch(r"s-[A-Za-z0-9_-]+\.lock", path.name))


def snapshot(path, category):
    def inspection_failed(error):
        raise Hold(f"Cannot inspect compiler cache: {error.filename or path}") from error

    nodes = [path]
    if path.is_dir() and not path.is_symlink():
        for directory, dirs, files in os.walk(path, followlinks=False, onerror=inspection_failed):
            nodes.extend(Path(directory) / name for name in dirs + files)
    amount, latest, identity, issues = 0, 0, [], []
    for node in nodes:
        value = node.lstat()
        identity.append((str(node.relative_to(path.parent)), value.st_dev, value.st_ino,
                         value.st_mtime_ns, value.st_ctime_ns, value.st_size))
        latest = max(latest, value.st_atime, value.st_mtime, value.st_ctime)
        amount += value.st_blocks * 512
        if stat.S_ISLNK(value.st_mode) or not (stat.S_ISREG(value.st_mode) or stat.S_ISDIR(value.st_mode)):
            issues.append("symlink or special file")
        elif value.st_uid != os.getuid():
            issues.append("different file owner")
        elif stat.S_ISREG(value.st_mode):
            if value.st_nlink != 1:
                issues.append("shared hard link")
            if not known_file(node, category):
                issues.append("unrecognized compiler file")
    return amount, latest, identity, sorted(set(issues))


def tracked_paths(root):
    result = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                            capture_output=True, timeout=30)
    if result.returncode:
        raise Hold("Cannot establish tracked-file preservation.")
    return [root / os.fsdecode(p) for p in result.stdout.split(b"\0") if p]


def plan(root, policy, now=None):
    now = time.time() if now is None else now
    tracked, units = tracked_paths(root), []
    for directory, category, output, locks in cache_roots(root):
        for path in sorted(directory.iterdir()):
            # Compiler bookkeeping is retained, including modules.timestamp.
            if path.name in ("modules.timestamp", "Session.modulevalidation"):
                continue
            amount, latest, identity, issues = snapshot(path, category)
            if any(p == path or path in p.parents for p in tracked):
                issues.append("tracked file")
            if category == "rust" and not re.fullmatch(r"[A-Za-z0-9_]+-[A-Za-z0-9]+", path.name):
                issues.append("unrecognized incremental unit")
            units.append(dict(path=path, category=category, output=output, locks=locks,
                              bytes=amount, latest=latest, identity=identity, issues=issues, reason=None))
    remaining = sum(u["bytes"] for u in units)
    for unit in sorted(units, key=lambda u: (u["latest"], str(u["path"]))):
        if unit["issues"]:
            continue
        age = now - unit["latest"]
        if age >= policy["cache_inactive_days"] * 86400:
            unit["reason"] = "inactive"
        elif remaining > policy["cache_max_gib"] * GIB and age >= policy["cache_grace_hours"] * 3600:
            unit["reason"] = "cache budget"
        if unit["reason"]:
            remaining -= unit["bytes"]
    return units, remaining


def cache_report(root, policy):
    now = time.time()
    units, remaining = plan(root, policy, now)

    def reason(unit):
        if unit["reason"]:
            return unit["reason"]
        if unit["issues"]:
            return "protected cache"
        if now - unit["latest"] < policy["cache_grace_hours"] * 3600:
            return "warm cache"
        return "within cache budget and inactivity window"

    return dict(bytes=sum(u["bytes"] for u in units), retained_bytes=remaining,
                budget_met=remaining <= policy["cache_max_gib"] * GIB,
                units=[dict(path=str(u["path"].relative_to(root)), bytes=u["bytes"],
                            last_change=u["latest"], action="remove" if u["reason"] else "keep",
                            reason=reason(u), held=u["issues"]) for u in units])


@contextmanager
def tool_locks(root, paths):
    fds = []
    try:
        found = False
        for path in paths:
            if path == swift_lock(root):
                if path.is_symlink():
                    raise Hold("Redirected SwiftPM lock; cache retained.")
            else:
                safe_path(root, path)
            if not path.exists():
                continue
            found = True
            fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
            fds.append(fd)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                name = str(path.relative_to(root)) if root in path.parents else "SwiftPM build lock"
                raise Hold(f"Toolchain lock busy: {name}") from error
        if not found:
            raise Hold("No recognized toolchain lock; cache retained.")
        yield
    finally:
        for fd in reversed(fds):
            os.close(fd)


def open_outputs(outputs):
    result = subprocess.run(["lsof", "-nP", "-a", "-u", str(os.getuid()), "-F", "pn"],
                            capture_output=True, text=True, timeout=30)
    if result.returncode not in (0, 1) or result.stderr.strip() or (result.returncode == 1 and not result.stdout):
        raise Hold("Open-file inspection unavailable; cache retained.")
    pid, busy = None, set()
    for line in result.stdout.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n/") and pid != os.getpid():
            path = Path(line[1:])
            for output in outputs:
                if path == output or output in path.parents:
                    busy.add(output)
    return busy


def remove_unit(root, unit):
    path = safe_path(root, unit["path"])
    current = snapshot(path, unit["category"])
    if current[2] != unit["identity"] or current[3] or current[1] > unit["latest"]:
        raise Hold(f"Cache changed during inspection: {path.relative_to(root)}")
    # Walk with directory descriptors, without following any ancestor symlink.
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parent.relative_to(root).parts:
            new = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = new
        value = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
        expected = unit["identity"][0]
        if (value.st_dev, value.st_ino, value.st_mtime_ns, value.st_ctime_ns, value.st_size) != tuple(expected[1:]):
            raise Hold("Cache identity changed; retained.")
        if stat.S_ISDIR(value.st_mode):
            if not shutil.rmtree.avoids_symlink_attacks:
                raise Hold("This Python runtime cannot remove directories safely; retained.")
            shutil.rmtree(path.name, dir_fd=fd)
        else:
            os.unlink(path.name, dir_fd=fd)
    finally:
        os.close(fd)


def prune(root, policy):
    units, remaining = plan(root, policy)
    result = dict(removed_bytes=0, removed=[], held=[])
    eligible = [u for u in units if u["reason"]]
    if not eligible:
        if remaining > policy["cache_max_gib"] * GIB:
            result["held"].append("cache budget exceeded; warm or unexplained files retained")
        return result
    for output in sorted(set(u["output"] for u in eligible)):
        group = [u for u in eligible if u["output"] == output]
        locks = list(dict.fromkeys(p for u in group for p in u["locks"]))
        try:
            with tool_locks(root, locks):
                if output in open_outputs([output]):
                    raise Hold(f"Active consumer uses {output.relative_to(root)}")
                # Recheck Git after acquiring both the build and toolchain locks.
                tracked = tracked_paths(root)
                for unit in group:
                    if any(p == unit["path"] or unit["path"] in p.parents for p in tracked):
                        raise Hold("Tracked cache content retained.")
                    remove_unit(root, unit)
                    result["removed"].append(str(unit["path"].relative_to(root)))
                    result["removed_bytes"] += unit["bytes"]
        except (OSError, Hold, subprocess.SubprocessError) as error:
            result["held"].append(str(error))
    retained = sum(u["bytes"] for u in units) - result["removed_bytes"]
    if retained > policy["cache_max_gib"] * GIB:
        result["held"].append("cache budget exceeded; protected or warm files retained")
    return result
