# Still Here

**Know what’s still running.** App: Still Here · command: `stillhere`.

Open source under [GPLv3](LICENSE) (`GPL-3.0-only`).
[Source and issues](https://github.com/rogu3bear/still-here) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) ·
[Third-party notices](NOTICE.md).

The first planned public release is **v0.1.0**. Earlier `0.3.x` version numbers
were internal development versions. Existing history and artifacts are retained.

Still Here finds the dev servers running on your Mac and traces each one to its
project, git branch and the coding agent session that started it. You get it
three ways, all answering from the same detector:

- a **menu bar app** with one dropdown for every server (the icon shows how many
  are running, the header how many are orphaned)
- a **`stillhere` command** for your terminal and scripts
- an **MCP server** (`stillhere mcp`) so Claude Code, Codex and other agents can
  wait for, list and clean up the servers they start

You know something is running, but the terminal is buried, the browser has an
old preview, and the agent may have finished hours ago. Open one list, find the
project behind the port, and decide what to keep. If you no longer need a
server, stop that exact process from the menu instead of hunting for its shell.
The web guide walks through this workflow and explains what each label proves.

Coding agents start dev servers all day, often in worktrees, and leave them
running when their session ends. Still Here names the agent behind each server
and flags the **orphans**: servers whose launching session has ended, so
nothing will stop them for you.

It also shows which agent sessions are working in which checkout, and warns
when two **independent** sessions share one working tree, where their edits
can overwrite each other. A session and a worker it started are not a
collision. A Claude Code hook can tell an agent about a collision before it
edits anything.

Each row shows:

- the port and URL (`http://localhost:<port>/`, or `https://` for TLS-only dev
  servers)
- the process name and PID
- the project folder (the process's working directory; hover for the full path)
- the git branch, and the worktree name for linked worktrees
- the coding agent that started it (Claude Code, Codex, …), in orange once
  orphaned
- a framework guess (Vite, Next.js, Astro, Remix, Rails, Django, Flask,
  FastAPI/uvicorn, Bun, Node, Python `http.server` and more)
- uptime
- HTTP status and page title, from a quick GET to the loopback address

Row actions: **Open** in the default browser, **Copy URL**, **Reveal** the
project in Finder, open the project folder in your **Terminal** app (iTerm2,
Ghostty, Warp or Terminal; see Settings), and **Stop**. Stop
asks for confirmation and sends SIGTERM. If that same process is still running
about 3 seconds later, it offers SIGKILL for it; if it exited and something else
now holds the port, nothing more is offered. Each signal goes to one process
(the server's root process, never a process group), and only after checking that
its start time and name have not changed, so a reused PID is never signalled.
After either signal, completion checks that captured identity again. If the
original process is gone or its PID has been reused, it is stopped; a replacement
listener is left untouched. Denied, refused, or failed verification and cancellation
stay unresolved, with no automatic escalation. A process still present after SIGKILL
is reported as still running rather than as a successful Stop.
Stop is never offered for system, daemon or app-helper listeners, and the app
never signals itself, launchd, or processes owned by another user.

**Flush** in the menu footer reviews orphaned servers and leftover development
processes, including Node workers that no longer have a listening port. Review
the captured names, PIDs and project folders, then confirm **Stop processes**.
Flush leaves active agent sessions, their hosts, descendants and processes in
their active checkouts running, including newly started sessions and reviewers.
Processes attached to a live terminal or app, launchd-managed services, ignored
listeners, and uncertain ownership are preserved. Unattributed detached processes must be in a Git
checkout and at least one minute old; arbitrary Python jobs are not included.
Each target is checked against a fresh ownership scan before SIGTERM and then
checked for exit using its captured identity. Flush never sends SIGKILL or adds
new processes after confirmation. Its result distinguishes stopped, preserved
and unresolved processes; a failed scan stops the remaining batch.

The list refreshes on a timer and whenever you open the menu. IPv4 and IPv6
listeners of one process tree on the same port appear as one entry; unrelated
processes sharing a port get separate entries.

## Requirements

- macOS 26 or later
- Apple silicon (arm64)

## Install

Previously named `term-web`. Saved General and Ignore List settings carry forward
on first launch; the CLI can read the legacy ignore list before that launch.
Update existing MCP configurations and hooks to invoke `stillhere`. Launch at
login belongs to the new app identity; enable it from the new installed copy.

The v0.1.0 public installer is still in preparation. The package workflow below
describes the intended installation once the signed, notarized artifact is
qualified and made available. You can use
[Build from source](#build-from-source) today.

Open `stillhere-<version>.pkg` and follow the installer. It installs
`/Applications/Still Here.app` and links the command-line tool at
`/usr/local/bin/stillhere`. Then open Still Here from Applications. It runs in
the menu bar only, with no Dock icon. Use **Quit** in the dropdown to exit.

To upgrade, install the new package the same way. The command-line tool (and
with it the hook and the MCP server) uses the new version at once; the menu
keeps running the old one until you **Quit** it and open Still Here again.

Until the package is notarized, Gatekeeper blocks it by default. See
[Notarization](#notarization).

## Command line

```sh
stillhere                      # table of running dev servers (same as `stillhere list`)
stillhere list --json          # stable JSON: every key present, null when unknown
stillhere list --mine          # servers started by the Claude Code session running this
stillhere list --orphans       # servers whose launching agent session has ended
stillhere wait 5173            # block until :5173 answers HTTP, print its URL (exit 1 on timeout)
stillhere open 5173            # open in the default browser (https when TLS-only)
stillhere stop 5173            # SIGTERM after confirming; --yes without a terminal, --force for SIGKILL
stillhere stop --orphans --yes # clean up every orphaned server
```

```sh
stillhere sessions             # agent sessions: checkouts, branches, servers, collisions
stillhere sessions --json      # the same, for tools
stillhere sessions --check     # for a SessionStart hook (see below)
```

`list --all` includes hidden listeners and `--no-probe` skips the HTTP check.
`stop` uses the same safety rules as the menu: one verified process, never
system, daemon or app-helper processes, and SIGKILL only on `--force` and only
to the same process. Exit codes: 0 success, 1 failure or timeout, 2 usage error.

## Coding agents (MCP)

`stillhere mcp` is an MCP server on stdio. Add it to Claude Code:

```sh
claude mcp add stillhere -- stillhere mcp
```

or to Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.stillhere]
command = "stillhere"
args = ["mcp"]
```

Tools:

- `list_servers` (`mine`, `orphans_only`, `include_hidden`, `port`)
- `list_sessions` (`include_idle`): agent sessions, their checkouts and
  servers, and collisions
- `wait_for_server` (`port`, `timeout_seconds` up to 120, `require_http`):
  use this after starting a dev server instead of sleeping
- `stop_server` (`port`, `pid`, `force`, `any_owner`): by default an agent can
  stop only the servers **its own session** started, so it can't stop your
  servers or another agent's unless it passes `any_owner` (after asking you).
  "Its own" matches the session ID or the running Claude Code process, so
  ownership survives `/clear` and resume.

The server speaks both MCP eras: the stateless 2026-07-28 revision
(per-request `_meta`, `server/discover`) and the `initialize` handshake of
2024-11-05 through 2025-11-25.

## Warn agents before they collide

Add a SessionStart hook to Claude Code (`~/.claude/settings.json`, or a
project's `.claude/settings.json`):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "stillhere sessions --check" }] }
    ]
  }
}
```

When another independent agent session is already working in the new
session's checkout, the hook adds a note to the new session's context naming
that session and asking the agent to check with you before editing files. The
hook runs again when a session is resumed, so the note asks only if you haven't
already told the agent how to proceed. It prints nothing otherwise and always
exits 0, so it never blocks a session.

## How agent tracing works

Coding agents mark the processes they start with environment variables, and a
dev server inherits them. Still Here reads **only** these variables from other
processes, and skips every other variable byte by byte without decoding it:

| Variable | Set by | Used for |
| --- | --- | --- |
| `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID` | Claude Code | agent, session, launcher liveness |
| `CODEX_SANDBOX` | Codex (sandboxed commands) | agent |
| `AI_AGENT` | agents that follow this convention | agent name |

When no marker is present, a live ancestor agent process identifies the
agent: by name (`claude`, `codex`, `cursor-agent`, `gemini`, `aider`,
`opencode`, `amp`), by executable path (the native Claude Code binary lives at
`~/.local/share/claude/versions/<version>`, so the kernel names it after its
version), or, for npm installs running under `node`, by the script in argv.

**Sessions** are those agent processes themselves. A session's checkouts are
the git checkouts that it and its descendant processes work in. Nested agent
processes are sessions of their own, recorded as workers of the session that
started them. App-hosted agents such as the Codex app server (`codex app-server`)
are placed only by their child processes' working directories. Their own is
wherever their host launched them: `/` for the desktop app, or the folder CCodex
was started from. Sessions that aren't in any checkout are hidden unless you
pass `--all`.

"Working in" is deliberately narrow, because a collision warning asks you to
act. A session works in the checkout of its own working directory, plus those
of descendants started in the last 10 minutes (the commands it is running now).
A dev server or MCP helper it started hours ago in another repo doesn't count;
that server is still linked to the session in the menu. Neither do helpers
shipped inside the agent's own app bundle, such as the REPL the Codex app server
starts in each thread's directory (including threads CCodex hands to Claude
Code); commands it runs there still count. Sessions younger than 5
seconds (one-shot `claude --version` and the like) don't count toward a
collision. A dotfiles repo at `~` is ignored.

**Roles.** Only *writers* collide. A session launched for review or with edits
disabled is a **reviewer**: it is listed ("reviewing") but never counts toward a
collision. Still Here decides this only from explicit launch flags on the agent
process: iTerm2's built-in code review (`--settings …/iTerm.app/Contents/Resources/code-review-settings.txt`),
Claude Code's `--permission-mode plan` or `--disallowedTools` covering both Edit
and Write, and Codex's `--sandbox read-only`. Everything else is a writer, so a
real collision is never hidden by a guess.

Limits: the Codex desktop app runs all its threads under one app server, so two
Codex threads in one checkout look like one session and never collide with
each other. Two sessions in one checkout are flagged whether or not both are
editing: Still Here can see where agents are, not what they will write.

A server is **orphaned** only when its launcher PID is known (Claude Code's
`CLAUDE_PID`) and that process has exited, or the PID now belongs to a process
started after the server. Agents that don't expose a launcher PID are named but
never called orphaned: Still Here does not guess.

The git branch and worktree come from reading `.git/HEAD` (or a worktree's
`.git` file) directly. No `git` process is run.

## Privacy

- Still Here makes no network connections except HTTP(S) requests to `127.0.0.1`
  and `::1` on the ports it found. There is no telemetry. For HTTPS it accepts
  self-signed certificates, only for those loopback addresses.
- From other processes' environments it reads only the agent markers listed
  above. It reads the arguments of agent processes (and of `node`) only to tell
  which agent they are and whether they are reviewers; the arguments, which can
  contain prompts, are never stored or reported. Command lines and environments never appear in `--json` or MCP output,
  because they can carry tokens.
- It has no entitlements and asks for no special permissions. It runs with the
  hardened runtime.
- It only sees processes that belong to you. Listeners owned by root or other
  users are skipped.
- To guess a framework, it reads `package.json`, `Gemfile`, `pyproject.toml`
  and similar files near a server's working directory. If a project lives under
  Documents, Desktop, Downloads or iCloud Drive, macOS may ask once whether
  Still Here can access that folder. Declining only makes the framework guess less
  specific.

## How detection works

Detection lives in the `StillHereCore` library, separate from the UI, and runs
off the main thread.

1. `lsof -nP -iTCP -sTCP:LISTEN -F pcRtn` lists your TCP listening sockets.
2. Sockets are grouped by port and process tree, so IPv4 and IPv6 become one
   entry and a forked parent and its workers become one server, while unrelated
   processes on the same port stay separate.
3. Process details (working directory, start time, parent PID, full argv) come
   from `libproc` and `sysctl(KERN_PROCARGS2)`.
4. A classifier hides system and non-dev listeners. A framework detector reads
   the command line, then the nearest project manifest, then HTTP response
   headers.
5. Visible servers get a short HTTP probe (status and `<title>`).

**Why libproc rather than `lsof -p <pid> -d cwd` for process details.** The
text path (`lsof -a -p PIDS -d cwd -Fn` plus `ps`) was measured at about 180 ms
of process spawning per refresh, compared with about 0.2 ms for libproc. More
importantly, `ps` cannot give an exact process start time, which Stop needs to
avoid signalling a reused PID, and it cannot give exact argv, because Next.js
rewrites its process title and `ps` joins arguments with spaces. The lsof-based
inspector is still implemented and tested as `LsofProcessInspector`.

## Hidden servers and the ignore list

These are hidden by default:

- executables under `/System`, `/usr/libexec`, `/usr/sbin` or `/Library/Apple`
- daemons whose working directory is `/` (ControlCenter/AirPlay, rapportd)
- helper processes inside other `.app` bundles
- processes named in the ignore list: ControlCenter, rapportd, sharingd,
  postgres, mysqld, redis-server, mongod, Dropbox, Spotify, `Code Helper*` and
  others. A trailing `*` matches a prefix.
- well-known database and broker ports: 5432, 3306, 6379, 27017, 11211, 9200,
  9300, 5672, 15672, 2379, 4222

Interpreters (`node`, `bun`, `deno`, `python*`, `ruby`, `php`, `java`) are
never hidden by the structural rules or the port list. Ports 5000, 7000, 8123
and 9000 are not on the port list, because dev servers use them. AirPlay is
hidden by process name instead.

Edit these in **Settings > Ignore List**. **Reset to Defaults** restores them.
Turn on **Show hidden servers** in **Settings > General** to list hidden
entries in their own section, each labelled with the reason it was hidden.

The command line and the MCP server use the same saved list, so
`stillhere list` and `list_servers` hide what the menu hides; `--all` and
`include_hidden` show everything. Turning off one of the first three rules
lists those processes, but Stop is still never offered for them.

## Settings

- **Refresh every:** 2, 3, 5 (default), 10 or 30 seconds
- **Show hidden servers**
- **Check HTTP status and page title**
- **Open folders in:** Automatic (the first installed of iTerm2, Ghostty and
  Warp, else Terminal) or a specific installed terminal
- **Launch at login:** uses `SMAppService`. Register it only from
  `/Applications/Still Here.app`. A copy run from `build/` registers that path
  instead. If macOS needs approval, the Settings window links to Login Items.

## Build from source

Requires Xcode 26 or later (Swift 6.2 or later).

```sh
git clone https://github.com/rogu3bear/still-here.git
cd still-here
python3 -B scripts/build.py swift build          # debug build
python3 -B scripts/build.py swift test           # unit tests (fake lsof output, no live processes)
python3 -B scripts/build.py swift run stillhere  # the CLI, from source
scripts/bundle.sh --dev      # build/Still Here.app, ad-hoc signed for local runs
open "build/Still Here.app"
```

Build scripts require Python 3.11 or later. The build entrypoint reuses `.build`,
rejects a second build while this checkout is busy, and applies the repository's
[cache retention policy](scripts/build-policy.json). Run
`python3 -B scripts/build.py report` to inspect disk use, or
`python3 -B scripts/build.py clean` to preview cleanup. See
[build storage and cleanup](CONTRIBUTING.md#build-storage-and-cleanup) for the
preservation rules and limits.

The project uses Swift Package Manager only. There is no Xcode project, because
SwiftPM builds the executables and the scripts assemble the `.app` bundle.
Targets: `StillHereCore` (detection, provenance, reports; no UI), `StillHereApp`
(the menu bar app, binary `StillHereApp`) and `StillHereCLI` (the `stillhere` command
and MCP server). The bundle carries both binaries in `Contents/MacOS`.

The version lives in `VERSION`. `bundle.sh` stamps it into the app's
`Info.plist`, `package.sh` uses it for the package version and file name, and
`StillHereVersion.current` (what `stillhere version` prints) must match it.
The minimum macOS (26.0) is set in `Package.swift`, `scripts/common.sh`,
`Packaging/Info.plist` and `Packaging/distribution.xml`.
`scripts/check-version-sync.sh` runs as part of every bundle build and fails if
any of these differ, or if the preferences domain the command-line tool reads
the ignore list from (`IgnoreConfiguration.preferencesDomain`) is not the app's
bundle identifier.

`scripts/make-icon.sh` regenerates `Packaging/AppIcon.icns` from
`scripts/make-icon.swift`. The generated icon is committed.

## Packaging

```sh
scripts/package.sh [--force] [--notary-profile NAME]
```

This script:

1. builds the release arm64 app and CLI and bundles `build/Still Here.app`
2. signs the CLI, then the app, with Developer ID Application, using the
   hardened runtime and a secure timestamp, with no entitlements
3. builds a component package that installs to `/Applications`, and a second
   one that links `/usr/local/bin/stillhere` to the CLI inside the app
4. builds a product archive from `Packaging/distribution.xml` (title, arm64
   host requirement, minimum macOS 26.0) and signs it with Developer ID
   Installer
5. writes `dist/stillhere-<VERSION>.pkg` and a `.sha256` file next to it
6. runs checks: `codesign --verify --deep --strict` on the app and on a copy
   extracted from the package, `pkgutil --check-signature`, checks that the
   payload contains both binaries with install location `/Applications` and
   the CLI link with the right target, and `spctl --assess`

The script will not overwrite an existing package for the same version. Bump
`VERSION`, delete the file, or pass `--force`.

Signing identities default to the MLNavigator Inc. (team 4JB58L7BTZ)
certificates. Override them with `APP_SIGN_ID` and `INSTALLER_SIGN_ID`, set to a
SHA-1 hash or a full certificate name from `security find-identity -v`.

Expected results before notarization: `spctl` rejects both the app and the
package with `source=Unnotarized Developer ID` (exit 3). The script reports this
and carries on.

**AppleDouble entries.** pkgbuild turns extended attributes into `._*`
entries in the payload. `package.sh` stages the app without extended attributes
and, when the host keeps re-applying `com.apple.provenance` (some agent and
sandboxed shells do, even outside the sandbox), rewrites the component package
without those entries. Any `._` entry left in the final payload fails the build.

## Notarization

Notarization runs only when you name a notarytool keychain profile. Without
one, `package.sh` sends nothing to Apple and prints these steps.

```sh
# once: store credentials with an app-specific password...
xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id 4JB58L7BTZ
# ...or with an App Store Connect API key
xcrun notarytool store-credentials <profile> --key AuthKey_XXXX.p8 --key-id <id> --issuer <uuid>

scripts/package.sh --force --notary-profile <profile>
```

With a profile, the script runs `notarytool submit --wait`, staples the ticket
to the package, validates the staple, and reruns `spctl`, which should then
report `source=Notarized Developer ID`. Only the explicit `--notary-profile`
argument enables notarization; the environment is never consulted.

## Troubleshooting

- **The Settings window opens behind other windows.** A menu bar app is not
  the active app when its panel closes. Still Here activates itself before opening
  Settings. If the window still ends up behind others, click the Still Here
  menu bar icon again or use Mission Control to bring it forward.
- **`stillhere: command not found`.** The installer links
  `/usr/local/bin/stillhere`; make sure `/usr/local/bin` is on your `PATH`, or
  run `/Applications/Still Here.app/Contents/MacOS/stillhere`.
- **A server shows no agent.** Only servers started while an agent's markers
  were in the environment, or whose agent process is still an ancestor, can be
  attributed. Servers started from your own shell correctly show none.
- **A server is missing.** Turn on **Show hidden servers** to see whether it
  was hidden and why, then edit the ignore list. Servers run by root or another
  user cannot be seen.
- **The status shows an error or timeout.** The probe waits only briefly. Some
  servers answer slowly on their first request. The next refresh tries again.
- **Launch at login does nothing.** Install the app into `/Applications` first,
  then turn the setting on again. Check System Settings > General > Login Items.

## License

Copyright (c) 2026 MLNavigator Inc. and contributors.

Still Here is licensed under [GNU GPL version 3 only](LICENSE)
(`GPL-3.0-only`). See [NOTICE.md](NOTICE.md) for retained template and font
license notices.

## Product website

The Leptos Cloudflare site lives in [website/](website/README.md). It includes
the product page, actual-screen gallery, seven-page guide, privacy details,
and XL/XXL/XXXL responsive layouts. The guide covers first run, menu actions,
Settings, the complete CLI, MCP setup, collision hooks, troubleshooting, and
v0.1.0 availability. Potential next features are in [IDEAS.md](IDEAS.md);
they are proposals, not current capabilities.
Cloudflare publication uses the governed `cfctl` workflow. See
[website release conditions](website/RELEASE.md).
