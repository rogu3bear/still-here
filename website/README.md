# Still Here website

The product site candidate for Still Here v0.1.0. Public deployment is pending.
Routes: `/`, `/screens`, `/privacy`, and the guide below.
Unknown routes return a server-rendered 404 with recovery links.

## Product guide

| Route | Reader task |
| --- | --- |
| `/docs` | Understand why the app helps and follow find → understand → stop. |
| `/docs/getting-started` | Requirements, current availability, source builds, first run, login, upgrades. |
| `/docs/menu-bar` | Read rows, use actions, understand confirmation and Settings. |
| `/docs/cli` | Complete command/flag reference, JSON shapes, readiness, and exit codes. |
| `/docs/agents` | Claude Code/Codex MCP setup, tools, ownership, and collision hooks. |
| `/docs/troubleshooting` | Missing listeners, unknown attribution, status errors, refused Stop, and limits. |
| `/docs/release` | v0.1.0 contents, version history, and pending installer availability. |

All guide pages are server-rendered with shared navigation. The original
`/docs#install`, `#cli`, `#mcp`, `#collisions`, and `#limits` anchors remain
useful entry points. Product behavior is checked against native source and CLI
help; client setup links its official documentation. Future ideas live in
`../IDEAS.md` and are not advertised as shipped functionality.

Built from the operator's Leptos Cloudflare template at
`c9054258839db3a2d85ecc5d2776922b8d717887`, adopted as `stillhere-site`.
The template's active dirty work was not copied or modified.

The site uses Leptos 0.8 SSR and hydration, the generated Cloudflare Worker
entrypoint `build/_worker.js`, Workers Assets at `target/site`, and the
inherited nonce CSP, request guards, cache rules, and operational telemetry.
The public route tree does not mount the template's example workflows or
compile their server functions. Template recipe sources and migration records
are retained for reference; the product pages do not use D1.

## Local build and preview

```sh
cd website
./scripts/check-deps.sh
./scripts/verify.sh
bun ./scripts/write-local-config.mjs
bunx wrangler@4.120.1 dev --config var/wrangler.local.toml --local --ip 127.0.0.1 --port 57583
```

Use the established Disk Guard admission for Rust builds. Keep this website's
`target`, `build`, and `var` independent of the template checkout. Build tools
are selected by the template's lockfile and existing scripts. The dependency
check and build prefer a repo-local `cargo-leptos 0.3.5` under
`var/cargo-tools/`; bootstrap installs that tool locally, preserving the global
version.

The local config snapshot preserves the canonical Worker, assets, and bindings.
It omits only the custom build command after the full build has completed, so
Wrangler validates/previews those artifacts without losing Disk Guard's
reservation descriptor during a redundant subprocess build. It is ignored and
never used as a production source of truth.

## Design and responsive behavior

The selected design closely follows the [original monochrome Refero reference](https://styles.refero.design/style/f24daf3a-d43f-4dec-85a9-8ac1d5148a03):
three-column hero, compact typography, centered native menu capture, monospaced
annotations, near-white canvas, and generous white space. Geist Sans and Geist
Mono 1.7.2 are self-hosted; the SIL license is included in `assets/fonts/`.
See `docs/DESIGN.md` for exact visual and capture provenance.

Layouts include mobile, intermediate, XL at 1280px, XXL at 1536px, and XXXL at
1920px. Content is capped at 1440px on ultrawide displays.

`/screens` shows full native views and original-resolution image links. Menu,
dark menu, Stop confirmation, and Flush review and result PNGs come from the actual SwiftUI views with
inert fixtures. Settings, Ignore List, and About JPEGs are CUA captures of the
displayed native windows. `../scripts/capture-site-images.sh` renders the menu
states and prepares isolated bundles in `../build/site-native/` for recapturing
Settings and About through CUA. Keep screenshot data inert; do not publish live
project metadata. The icon is the unchanged PNG resource extracted from the
native app's `Packaging/AppIcon.icns`.

## Release and hosting

Cloudflare publication goes through `cfctl`, following the governed plan,
approval, execution, and provider-readback contract. The user authorized a
Still Here v0.1.0 routing exception for this launch's chat to execute directly;
see `RELEASE.md` for its scope and required exact-plan approval. Local Wrangler
is used only for local preview and deployment dry runs.

The requested public target is Cloudflare Pages with its generated `pages.dev`
hostname. `bun scripts/export-pages.mjs` crawls the ten linked product routes
from the qualified local Worker, writes each complete HTML page and a real 404,
copies the fingerprinted assets, and generates script-hash CSP headers. The
result is an ignored, versioned `var/pages/` artifact with a SHA-256 inventory
in `var/pages-export.json`. It needs no Pages Functions, D1, or secrets. The
Leptos source and hydration remain the same as the Worker preview. The export
inventory is local evidence, not a cfctl authenticated reproduction receipt.

The product is open source under GPL-3.0-only. Source and issues are at
https://github.com/rogu3bear/still-here. The original template MIT notice and
Geist font license are retained; see `../NOTICE.md`. The installer area states that the
first public installer is in preparation, pending signing and Apple notarization.
