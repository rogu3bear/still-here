use super::docs_layout::DocsLayout;
use super::product::SOURCE_URL;
use leptos::prelude::*;
use leptos_meta::Title;

#[component]
pub fn ReleaseGuidePage() -> impl IntoView {
    view! {
        <Title text="v0.1.0 — Still Here"/>
        <DocsLayout active="release">
            <p class="eyebrow">"THE FIRST PUBLIC VERSION"</p><h1>"Still Here v0.1.0"</h1>
            <p class="doc-lead">"One view of your local servers, their projects, and the agents behind them. The first public installer is in preparation."</p>
            <section><h2>"What’s in this version"</h2><ul><li>"A native Mac menu bar app with server context and confirmed Stop."</li><li>"Flush reviews orphaned servers and leftover development processes while protecting active sessions and their checkouts."</li><li>"Project, branch, worktree, framework, uptime, and local HTTP response details."</li><li>"Agent attribution, evidence-based orphan labels, and checkout collision warnings."</li><li>"A CLI for listing, opening, waiting, stopping, and inspecting sessions."</li><li>"A local stdio MCP server and a Claude Code collision hook."</li><li>"Shared ignore settings across the menu, CLI, and MCP server."</li></ul><a class="text-link" href="/docs/menu-bar#flush" target="_self">"How Flush chooses processes →"</a></section>
            <section><h2>"Why v0.1.0?"</h2><p>"Earlier 0.3.x labels were internal development versions. v0.1.0 names the first planned public release; those older labels do not mean a newer public release exists."</p></section>
            <section><h2>"Availability"</h2><a class="text-link" href=SOURCE_URL target="_blank" rel="noopener noreferrer">"Get the source ↗"</a><p>"Requires Apple silicon and macOS 26 or later. A public download will be offered after the installer has completed signing, Apple notarization, and installation checks. This site currently has no installer download."</p><p>"The source is open under GPLv3, and you can build it locally. Proposed future features are not part of this version."</p><a class="text-link" href="/docs/getting-started">"Build and first-run guide →"</a></section>
            <section><h2>"Read before relying on a label"</h2><p>"Orphaned means a known launcher ended; ready means the server answered. Agent identity may be unknown, and Codex desktop chats cannot be distinguished for collision detection. Read the guide’s limits for the complete context."</p><a class="text-link" href="/docs/troubleshooting#limits" target="_self">"Known limits →"</a></section>
        </DocsLayout>
    }
}
