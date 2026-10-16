# Contributing to Still Here

Still Here helps people find local development servers, understand their
projects and ownership evidence, and stop a specific process with confirmation.
The menu bar app, CLI, and MCP server share the same detection library.

## Build the Mac app

Use an Apple silicon Mac with macOS 26 or later and Xcode 26 or later
(Swift 6.2 or later).

```sh
git clone https://github.com/rogu3bear/stillhere.git
cd stillhere
python3 -B scripts/build.py swift build
python3 -B scripts/build.py swift test
scripts/bundle.sh --dev
open "build/Still Here.app"
.build/debug/stillhere help
```

The development bundle is signed ad hoc for local use. Building it does not
install a global command, register a login item, or produce a notarized installer.
The public installer remains in preparation.

## Choose the right part

- `Sources/StillHereCore`: discovery, classification, provenance, shared reports,
  saved ignore settings, and process identity checks.
- `Sources/StillHereApp`: the native menu, settings, stores, and actions.
- `Sources/StillHereCLI`: commands, JSON output, and the stdio MCP server.
- `Tests`: deterministic fixtures and behavioral tests.
- `website`: the Leptos product site and user guide. Follow its
  [contributor guide](website/CONTRIBUTING.md) and local verification scripts.

Keep network access restricted to detected loopback servers. Preserve the
process identity checks and confirmation behavior around Stop. Missing agent
attribution stays unknown; do not infer ownership from a convenient label.
Use inert sample projects in screenshots and tests.

## Before a pull request

Run `python3 -B scripts/build.py swift test` and `scripts/check-version-sync.sh` for native changes.
Run `./scripts/verify.sh` from `website` for website changes, then inspect the
affected pages at mobile and desktop widths. Local checks are authoritative;
this repository does not use GitHub Actions.

Describe the concrete problem, resulting behavior, and checks you ran. Add a
behavioral test when a change affects detection, ownership, stopping, or saved
settings. Keep generated bundles, installers, local provider records, and
credentials out of Git. Follow [SECURITY.md](SECURITY.md) for vulnerability
reports. Contributions use GPL-3.0-only; preserve third-party notices.

## Build storage and cleanup

Python 3.11+ and `lsof` are required for build maintenance on macOS. Use the
entrypoint above for native build/test/run. Existing bundle, package, screenshot,
icon, website build, bootstrap and verification scripts also acquire the same
checkout lock. A conflicting invocation exits 75 before starting another build;
reuse the running owner's result, then rerun if different work is needed. Nested
scripts validate and reuse the inherited lock. Kernel locks release on exit or
crash; lock files remain in place, so do not delete them to recover a build.

```sh
python3 -B scripts/build.py report       # sizes, policy and retention plan
python3 -B scripts/build.py clean        # preview only
python3 -B scripts/build.py clean --apply
python3 -B -m unittest discover -s Tests/BuildSupportTests -v
```

[build-policy.json](scripts/build-policy.json) retains warm compiler caches for
at least 24 hours, expires inactive caches after 14 days, and limits their
combined retained size to 1 GiB when older eligible entries can be removed.
Age uses the latest recorded file access or file/directory modification or
change. Directory access times are excluded because inspection itself reads
directories. Filesystems that do not record access times use change times as
the retention signal.
Maintenance runs before each outer build and after successful completion.
Failures skip post-build cleanup. It removes only recognized Swift module/SDK
cache entries and Rust incremental units under `.build`, `website/target` and
`website/var/cargo-tools/target`. It checks toolchain locks, open files, ownership,
Git-tracked files, path identity and contents immediately before removal.
Symlinks, hard links, unknown contents, active consumers and inspection failures
hold cleanup. Compilation databases, Cargo dependency artifacts, tool binaries,
app bundles, installers, source, website assets and captured evidence are retained.
An unreadable directory stops cache inspection before any removal; unobserved
contents never qualify as a disposable cache.
The standalone website template works without the native controller.

A successful cleanup can remove zero bytes when the caches are warm or within
the budget and inactivity window. Every report entry includes its retention or
removal reason. `shared hard link` means another path references the same file,
as Rust commonly does between incremental caches and dependency artifacts; it
does not represent a second copy of the file's contents. Unknown file names are
reported separately as `unrecognized compiler file` and are also retained.

The policy holds new builds below 10 GiB of free space or when native output
exceeds 4 GiB or website plus tool-build output exceeds 12 GiB. Those are
admission limits, not filesystem quotas: a single build can cross them, and the
next build holds. Protected or recently used files can keep the cache above its
budget; the report explains what is retained. Review their actual owner before
further cleanup. The installed shared Disk Guard, when available, also admits
native Swift compilation with a 3 GB peak-growth allowance and preserves its
own reserve and inherited reservations. Website Cargo retains its existing
Disk Guard path. This mechanism changes no global policy, shell tool or service.

The bundle builds both native products once. Tool installation reuses one
repository-local Cargo target directory instead of fresh temporary builds.
Successful packaging removes its payload staging copies after all checks;
failure staging remains. Maintenance events are bounded to two approximately
1 MiB logs in ignored `build/.maintenance`. No scheduler is installed. Direct
`swift`/`cargo`, IDE routes, custom output directories and builds of an adopted
standalone website bypass this repository entrypoint. Use the documented scripts
for automatic retention and serialization.
