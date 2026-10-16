"""Behavioral checks for deletion boundaries and real kernel-lock ownership."""
import fcntl
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import build
import build_cache as cache


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPTS / "build-policy.json", self.root / "scripts/build-policy.json")
        self.policy = build.load_policy(self.root)
        self.now = time.time() + 30 * 86400
        self.write(".build/.lock", b"")
        cache.swift_lock(self.root).write_bytes(b"")
        self.addCleanup(cache.swift_lock(self.root).unlink)

    def write(self, relative, data=b"test artifact\n"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def swift_cache(self, key="HASH"):
        return self.write(f".build/out/ModuleCache.noindex/{key}/Foundation-ABC.pcm")

    def prune(self):
        with patch.object(cache.time, "time", return_value=self.now), \
                patch.object(cache, "open_outputs", return_value=set()):
            return cache.prune(self.root, self.policy)

    def test_expired_cache_removed_products_source_and_evidence_retained(self):
        obsolete = self.swift_cache()
        paths = [self.write(name) for name in (
            "Sources/File.swift", ".build/out/Products/Debug/stillhere",
            ".build/out/Intermediates.noindex/XCBuildData/build.db",
            "website/target/release/deps/libcrate.rlib", "website/target/site/pkg/app.wasm",
            "website/var/cargo-tools/wasm-bindgen-1/bin/wasm-bindgen",
            "build/Still Here.app/Contents/MacOS/StillHereApp",
            "build/failed-review/receipt.json", "dist/signed.pkg")]
        before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths]
        result = self.prune()
        self.assertFalse(obsolete.exists())
        self.assertGreater(result["removed_bytes"], 0)
        self.assertFalse(result["held"])
        self.assertEqual(before, [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths])

    def test_preview_does_not_delete(self):
        path = self.swift_cache()
        with patch.object(cache.time, "time", return_value=self.now):
            report = cache.cache_report(self.root, self.policy)
        self.assertEqual(report["units"][0]["action"], "remove")
        self.assertEqual(report["units"][0]["reason"], "inactive")
        self.assertTrue(path.exists())

    def test_report_explains_warm_and_idle_cache_retention(self):
        path = self.swift_cache()
        latest = cache.snapshot(path.parent, "swift")[1]
        for age, reason in ((3600, "warm cache"),
                           (2 * 86400, "within cache budget and inactivity window")):
            with patch.object(cache.time, "time", return_value=latest + age):
                unit = cache.cache_report(self.root, self.policy)["units"][0]
            self.assertEqual(unit["action"], "keep")
            self.assertEqual(unit["reason"], reason)
            self.assertEqual(unit["held"], [])
        self.assertTrue(path.exists())

    def test_report_distinguishes_shared_rust_file_from_unknown_content(self):
        path = self.write("website/target/debug/incremental/crate-abc123/s-hash/metadata.rmeta")
        product = self.root / "website/target/debug/deps/libcrate.rmeta"
        product.parent.mkdir()
        os.link(path, product)
        unit = cache.cache_report(self.root, self.policy)["units"][0]
        self.assertEqual(unit["reason"], "protected cache")
        self.assertEqual(unit["held"], ["shared hard link"])
        self.write("website/target/debug/incremental/crate-abc123/s-hash/measurement.json")
        unit = cache.cache_report(self.root, self.policy)["units"][0]
        self.assertEqual(unit["held"], ["shared hard link", "unrecognized compiler file"])
        self.assertEqual(self.prune()["removed"], [])
        self.assertTrue(path.exists())
        self.assertTrue(product.exists())

    def test_warm_cache_kept_even_above_budget(self):
        path = self.swift_cache()
        self.policy["cache_max_gib"] = 1e-9
        self.now = time.time()
        result = self.prune()
        self.assertTrue(path.exists())
        self.assertEqual(result["removed"], [])
        self.assertTrue(result["held"])

    def test_budget_removes_oldest_idle_unit_and_keeps_newer_unit(self):
        old, new = self.swift_cache("OLD"), self.swift_cache("NEW")
        original = cache.snapshot

        def controlled_age(path, category):
            amount, latest, identity, issues = original(path, category)
            age = 72 if path.name == "OLD" else 48
            return amount, self.now - age * 3600, identity, issues

        self.policy["cache_max_gib"] = original(new.parent, "swift")[0] / cache.GIB
        with patch.object(cache, "snapshot", side_effect=controlled_age):
            result = self.prune()
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())
        self.assertEqual(len(result["removed"]), 1)

    def test_unknown_file_protects_entire_unit(self):
        path = self.swift_cache()
        evidence = self.write(str(path.parent.relative_to(self.root) / "measurement.json"))
        self.assertEqual(self.prune()["removed"], [])
        self.assertTrue(path.exists())
        self.assertTrue(evidence.exists())

    def test_tracked_compiler_named_file_retained(self):
        path = self.swift_cache()
        subprocess.run(["git", "-C", str(self.root), "add", str(path)], check=True)
        self.assertEqual(self.prune()["removed"], [])
        self.assertTrue(path.exists())

    def test_symlink_inside_cache_does_not_remove_external_data(self):
        path = self.swift_cache()
        external = self.write("precious/source.pcm")
        (path.parent / "alias.pcm").symlink_to(external)
        self.assertEqual(self.prune()["removed"], [])
        self.assertTrue(external.exists())
        self.assertTrue(path.exists())

    def test_output_root_symlink_rejected_even_inside_checkout(self):
        shutil.rmtree(self.root / ".build")
        external = self.root / "owned"
        external.mkdir()
        (self.root / ".build").symlink_to(external)
        with self.assertRaisesRegex(cache.Hold, "Symlinked"):
            cache.cache_report(self.root, self.policy)

    def test_hard_link_preserved(self):
        path = self.swift_cache()
        os.link(path, self.root / "retained.pcm")
        self.assertEqual(self.prune()["removed"], [])
        self.assertTrue(path.exists())

    def test_busy_native_toolchain_lock_holds_cleanup(self):
        path = self.swift_cache()
        fd = os.open(cache.swift_lock(self.root), os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            result = self.prune()
        finally:
            os.close(fd)
        self.assertTrue(path.exists())
        self.assertIn("lock busy", result["held"][0])

    def test_missing_toolchain_lock_holds_cleanup(self):
        path = self.swift_cache()
        cache.swift_lock(self.root).unlink()
        # Fixture teardown owns this disposable lock and expects it to exist.
        self.addCleanup(lambda: cache.swift_lock(self.root).touch())
        result = self.prune()
        self.assertTrue(path.exists())
        self.assertIn("No recognized", result["held"][0])

    def test_active_output_consumer_holds_cleanup(self):
        path = self.swift_cache()
        with patch.object(cache.time, "time", return_value=self.now), \
                patch.object(cache, "open_outputs", return_value={self.root / ".build"}):
            result = cache.prune(self.root, self.policy)
        self.assertTrue(path.exists())
        self.assertIn("Active consumer", result["held"][0])

    def test_inspection_failure_holds_cleanup(self):
        path = self.swift_cache()
        with patch.object(cache.time, "time", return_value=self.now), \
                patch.object(cache, "open_outputs", side_effect=cache.Hold("inspection unavailable")):
            result = cache.prune(self.root, self.policy)
        self.assertTrue(path.exists())
        self.assertIn("inspection unavailable", result["held"])

    def test_directory_scan_failure_cannot_report_an_eligible_cache(self):
        path = self.swift_cache()
        hidden = self.write(".build/out/ModuleCache.noindex/HASH/unreadable/unknown-evidence.txt")
        scandir = cache.os.scandir

        def inspect(directory):
            if Path(directory) == hidden.parent:
                raise PermissionError(errno.EACCES, "inspection unavailable", str(directory))
            return scandir(directory)

        with patch.object(cache.os, "scandir", side_effect=inspect):
            with self.assertRaisesRegex(cache.Hold, "Cannot inspect compiler cache"):
                cache.cache_report(self.root, self.policy)
        self.assertTrue(path.exists())
        self.assertEqual(hidden.read_bytes(), b"test artifact\n")

    @unittest.skipIf(os.geteuid() == 0, "Directory permissions require an unprivileged test user")
    def test_unreadable_directory_retains_cache_and_unknown_contents(self):
        path = self.swift_cache()
        hidden = self.write(".build/out/ModuleCache.noindex/HASH/unreadable/unknown-evidence.txt")
        hidden.parent.chmod(0)
        try:
            try:
                result = self.prune()
            except cache.Hold as error:
                self.assertIn("Cannot inspect compiler cache", str(error))
            else:
                self.assertTrue(result["held"])
                self.assertEqual(result["removed"], [])
            self.assertTrue(path.exists(), "Inspection failure must retain already-inspected siblings")
        finally:
            hidden.parent.chmod(0o700)
        self.assertEqual(hidden.read_bytes(), b"test artifact\n")

    def test_identity_change_between_plan_and_removal_retains_data(self):
        path = self.swift_cache()
        units, _ = cache.plan(self.root, self.policy, self.now)
        path.write_bytes(b"new bytes")
        with self.assertRaisesRegex(cache.Hold, "changed"):
            cache.remove_unit(self.root, units[0])
        self.assertEqual(path.read_bytes(), b"new bytes")

    def test_rust_incremental_layouts_and_products(self):
        paths = []
        for base in ("website/target/debug", "website/target/wasm32-unknown-unknown/release",
                     "website/target/front/wasm32-unknown-unknown/release",
                     "website/var/cargo-tools/target/release"):
            self.write(base + "/.cargo-lock", b"")
            paths.append(self.write(base + "/incremental/crate-abc123/s-hash/dep-graph.bin"))
        product = self.write("website/target/front/wasm32-unknown-unknown/release/app.wasm")
        result = self.prune()
        self.assertEqual(len(result["removed"]), 4)
        self.assertTrue(product.exists())
        self.assertTrue(all(not p.exists() for p in paths))

    def test_lock_contention_rejects_second_build_before_child(self):
        first, second = {}, {}
        with build.lease(self.root, first):
            with patch.object(build, "child") as child:
                with self.assertRaisesRegex(cache.Hold, "Another build"):
                    build.execute(self.root, self.policy, ["unused"], self.root, second)
            child.assert_not_called()

    def test_nested_process_validates_same_inherited_lease(self):
        env = dict(os.environ)
        with build.lease(self.root, env) as (fd, owner):
            self.assertTrue(owner)
            code = ("import os,sys; from pathlib import Path; "
                    f"sys.path.insert(0,{str(SCRIPTS)!r}); import build; "
                    "assert build.inherited(Path(sys.argv[1]), os.environ) is not None")
            status = build.child([sys.executable, "-B", "-c", code, str(self.root)], env, fd, self.root)
        self.assertEqual(status, 0)

    def test_stale_lease_holds_instead_of_bypassing(self):
        env = {}
        with build.lease(self.root, env):
            pass
        with self.assertRaisesRegex(cache.Hold, "Invalid inherited"):
            build.inherited(self.root, env)

    def test_dead_owner_releases_lock_without_unlinking(self):
        env = dict(os.environ)
        code = ("import os,sys; from pathlib import Path; "
                f"sys.path.insert(0,{str(SCRIPTS)!r}); import build; "
                "ctx=build.lease(Path(sys.argv[1]),dict(os.environ)); ctx.__enter__(); "
                "print('locked',flush=True); sys.stdin.read()")
        process = subprocess.Popen([sys.executable, "-B", "-c", code, str(self.root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        try:
            self.assertEqual(process.stdout.readline().strip(), "locked")
            identity = (self.root / "build/.maintenance/build.lock").stat().st_ino
            process.kill()
            process.wait(timeout=10)
            with build.lease(self.root, {}):
                self.assertEqual((self.root / "build/.maintenance/build.lock").stat().st_ino, identity)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdin.close()
            process.stdout.close()

    def test_child_preserves_outer_disk_guard_descriptor(self):
        env = dict(os.environ)
        reserve_fd = os.open(self.root / ".build/.lock", os.O_RDWR)
        try:
            env["DISK_GUARD_RESERVATION"] = json.dumps(dict(fd=reserve_fd))
            with build.lease(self.root, env) as (fd, _):
                code = f"import os; os.fstat({reserve_fd})"
                self.assertEqual(build.child([sys.executable, "-B", "-c", code], env, fd, self.root), 0)
        finally:
            os.close(reserve_fd)

    def test_failure_preserves_exit_and_skips_post_build_cleanup(self):
        with patch.object(build, "maintain") as maintain:
            status = build.execute(self.root, self.policy,
                                   [sys.executable, "-c", "raise SystemExit(7)"], self.root, dict(os.environ))
        self.assertEqual(status, 7)
        self.assertEqual(maintain.call_count, 1)

    def test_capacity_limits_hold_before_child(self):
        with patch.object(build.shutil, "disk_usage", return_value=shutil._ntuple_diskusage(100, 99, 1)), \
                patch.object(build, "child") as child:
            with self.assertRaisesRegex(cache.Hold, "Free disk"):
                build.execute(self.root, self.policy, ["unused"], self.root, {})
        child.assert_not_called()
        self.swift_cache()
        self.policy["native_max_gib"] = 1e-9
        with self.assertRaisesRegex(cache.Hold, "output exceeds"):
            build.preflight(self.root, self.policy)

    def test_native_run_flags_precede_product_and_redirects_hold(self):
        with patch.object(build.shutil, "which", return_value=None):
            command = build.swift_command(self.root, self.policy, ["run", "stillhere", "help"])
            self.assertLess(command.index("--scratch-path"), command.index("stillhere"))
            for argument in ("--scratch-path=other", "--package-path"):
                with self.assertRaises(cache.Hold):
                    build.swift_command(self.root, self.policy, ["build", argument])

    def test_policy_rejects_invalid_limits(self):
        for value in (0, -1, True, "large", float("nan")):
            data = dict(self.policy, cache_max_gib=value)
            (self.root / "scripts/build-policy.json").write_text(json.dumps(data))
            with self.assertRaises(cache.Hold):
                build.load_policy(self.root)

    def test_old_python_holds_before_maintenance(self):
        with patch.object(build.sys, "version_info", (3, 10)):
            with self.assertRaisesRegex(cache.Hold, "Python 3.11"):
                build.check_runtime()

    def test_event_logs_rotate_without_accumulating_copies(self):
        state = build.state_dir(self.root)
        for iteration in range(3):
            (state / "events.jsonl").write_text("x" * (1024 ** 2))
            build.record(self.root, dict(kind="fixture", iteration=iteration))
        self.assertEqual(len(list(state.glob("*.jsonl"))), 2)
        self.assertEqual(json.loads((state / "events.jsonl").read_text())["iteration"], 2)

    def shell_fixture(self):
        # Exercise the actual scripts and nested controller in an isolated,
        # unsigned fixture. Apple signing/notary tools never run in this test.
        for path in SCRIPTS.glob("*"):
            if path.is_file():
                shutil.copy2(path, self.root / "scripts" / path.name)
        shutil.copytree(SCRIPTS.parent / "Packaging", self.root / "Packaging")
        shutil.copy2(SCRIPTS.parent / "VERSION", self.root / "VERSION")
        shutil.copy2(SCRIPTS.parent / "LICENSE", self.root / "LICENSE")
        (self.root / "scripts/check-version-sync.sh").write_text("#!/bin/bash\nexit 0\n")
        (self.root / "scripts/check-version-sync.sh").chmod(0o755)
        tools = self.root / "fixture-tools"
        tools.mkdir()
        stub = tools / "tool.py"
        stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, subprocess, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root/'tool-calls.jsonl').open('a') as f:
    f.write(json.dumps([name,args])+'\\n')
if name == os.environ.get('FAIL_TOOL'): sys.exit(9)
if name == 'disk-guard':
    sys.exit(subprocess.call(args[args.index('--')+1:]))
if name == 'swift':
    out = root/'.build/out/Products/Release'
    out.mkdir(parents=True, exist_ok=True)
    if '--show-bin-path' in args: print(out)
    else:
        for binary in ('StillHereApp', 'stillhere'):
            (out/binary).write_text('fixture binary')
            (out/binary).chmod(0o755)
elif name == 'codesign' and '-dvv' in args:
    print('flags=0x10000(runtime)\\nTeamIdentifier=4JB58L7BTZ\\nTimestamp=fixture',file=sys.stderr)
elif name == 'ditto':
    shutil.copytree(args[-2], args[-1], symlinks=True)
elif name == 'pkgbuild':
    if '--analyze' in args:
        pathlib.Path(args[-1]).write_bytes(plistlib.dumps([{'BundleIsRelocatable':True}]))
    else: pathlib.Path(args[-1]).write_text('fixture component')
elif name == 'productbuild': pathlib.Path(args[-1]).write_text('fixture signed package')
elif name == 'pkgutil':
    if '--payload-files' in args:
        if args[-1].endswith('-cli-component.pkg'): print('./usr/local/bin/stillhere')
        else: print('./Still Here.app\\n./Still Here.app/Contents/MacOS/StillHereApp\\n./Still Here.app/Contents/MacOS/stillhere')
    elif '--expand' in args:
        out = pathlib.Path(args[-1]); out.mkdir()
        component = out/'stillhere-component.pkg'; component.mkdir()
        (component/'PackageInfo').write_text('<pkg-info install-location="/Applications"/>')
        (out/'Distribution').write_text('<options hostArchitectures="arm64"/>')
    elif '--expand-full' in args:
        out = pathlib.Path(args[-1]); out.mkdir()
        shutil.copytree(root/'build/Still Here.app', out/'stillhere-component.pkg/Payload/Still Here.app')
        link = out/'stillhere-cli-component.pkg/Payload/usr/local/bin/stillhere'
        link.parent.mkdir(parents=True)
        link.symlink_to('/Applications/Still Here.app/Contents/MacOS/stillhere')
''')
        stub.chmod(0o755)
        for tool in ("swift", "disk-guard", "codesign", "ditto", "pkgbuild", "productbuild", "pkgutil", "xattr", "spctl", "xcrun"):
            (tools / tool).symlink_to(stub)
        return dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], FIXTURE_ROOT=str(self.root))

    def shell_run(self, script, args, env):
        return subprocess.run(["bash", str(self.root / "scripts" / script), *args],
                              cwd=self.root, env=env, capture_output=True, text=True, timeout=30)

    def test_bundle_reentry_preserves_dev_flag_and_builds_both_products_once(self):
        env = self.shell_fixture()
        result = self.shell_run("bundle.sh", ["--dev"], env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / "tool-calls.jsonl").read_text().splitlines()]
        builds = [args for name, args in calls if name == "swift" and "--show-bin-path" not in args]
        self.assertEqual(len(builds), 1)
        self.assertNotIn("--product", builds[0])
        self.assertEqual(len([args for name, args in calls if name == "codesign" and "-" in args]), 2)
        for binary in ("StillHereApp", "stillhere"):
            self.assertTrue((self.root / "build/Still Here.app/Contents/MacOS" / binary).exists())

    def test_package_reentry_preserves_force_and_profile_cleans_success_staging(self):
        env = self.shell_fixture()
        self.write("dist/stillhere-0.1.0.pkg", b"existing fixture")
        result = self.shell_run("package.sh", ["--force", "--notary-profile", "fixture-profile"], env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / "tool-calls.jsonl").read_text().splitlines()]
        self.assertTrue(any(name == "xcrun" and "fixture-profile" in args for name, args in calls))
        for stage in ("pkgroot", "cliroot", "expanded", "full"):
            self.assertFalse((self.root / "build" / stage).exists())
        for retained in ("build/Still Here.app", "build/stillhere-component.pkg",
                         "dist/stillhere-0.1.0.pkg", "dist/stillhere-0.1.0.pkg.sha256"):
            self.assertTrue((self.root / retained).exists())

    def test_failed_package_retains_staging_and_exit_code(self):
        env = dict(self.shell_fixture(), FAIL_TOOL="productbuild")
        result = self.shell_run("package.sh", [], env)
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
        self.assertTrue((self.root / "build/pkgroot/Still Here.app").exists())
        self.assertTrue((self.root / "build/cliroot").exists())


if __name__ == "__main__":
    unittest.main()
