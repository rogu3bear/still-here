use super::product::{CodeBlock, NativeScreen, INSTALLER_URL, VERSION};
use leptos::prelude::*;
use leptos_meta::Title;

#[component]
pub fn HomePage() -> impl IntoView {
    view! {
        <Title text="Still Here — Know what’s still running."/>
        <section class="hero wrap" aria-labelledby="hero-title">
            <div class="hero-copy">
                <h1 id="hero-title">"Know what’s"<br/>"still running."</h1>
                <p class="hero-description">"See every local server, its project, and the agent behind it. Right from your Mac’s menu bar."</p>
                <div class="actions"><a class="button" href="#download" target="_self">"Get Still Here"</a><a class="button button-outline" href="/screens">"See the app"</a></div>
                <p class="requirements">"v" {VERSION} " · Apple silicon · macOS 26+"</p>
            </div>
            <figure class="hero-screen">
                <figcaption>"THE MENU BAR / LIGHT"</figcaption>
                <a href="/images/menu-bar.png" target="_self" aria-label="Open the original menu bar capture"><img src="/images/menu-bar.png" alt="The actual Still Here menu showing three local servers, their projects, and coding agents" width="800" height="712" fetchpriority="high"/></a>
                <p>"Actual app view · sample projects"</p>
            </figure>
            <div class="hero-annotation"><p>"FOR LOCAL DEVELOPMENT"</p><p>"EVERY SERVER AND SESSION"</p><p>"RIGHT IN YOUR MENU BAR"</p></div>
        </section>
        <div class="capability-strip wrap" aria-label="Product interfaces"><p>"ONE DETECTOR. THREE WAYS IN."</p><span>"Menu bar"</span><span>"Command line"</span><span>"MCP for your agents"</span></div>
        <section class="workflow-section wrap section" aria-labelledby="workflow-title">
            <p class="eyebrow">"WHEN YOU’VE LOST TRACK"</p><h2 id="workflow-title">"Something’s running."<br/>"Find the loose ends."</h2>
            <div class="workflow-grid">
                <article><h3>"A port is already busy."</h3><p>"See the project using it, open its folder, and decide whether to keep the server or stop it before starting another."</p></article>
                <article><h3>"The agent left a preview behind."</h3><p>"Find servers whose known launcher has ended. Check what they belong to, then stop the ones you no longer need."</p></article>
                <article><h3>"The browser has the wrong branch."</h3><p>"Match each preview to its checkout and worktree. Open the right one without retracing every terminal."</p></article>
            </div>
            <a class="text-link" href="/docs">"Find it. Understand it. Take it out. →"</a>
        </section>
        <section class="screens-preview wrap section" id="inside" aria-labelledby="screens-title">
            <div class="screens-heading"><h2 id="screens-title">"Know what’s running."<br/>"See the whole picture."</h2><p>"The real macOS interface. Every server, its project, and the agent behind it. Exact native views, shown in full."</p></div>
            <div class="screens-preview-grid">
                <NativeScreen src="menu-bar.png" label="01 / MENU BAR" description="Servers, branches, agent ownership, and checkout collisions." width=800 height=712/>
                <NativeScreen src="settings.jpg" label="02 / SETTINGS" description="Refresh, localhost status checks, terminal choice, and launch at login." width=960 height=1104/>
            </div>
            <p class="capture-note">"Native SwiftUI and AppKit captures with sample projects. "<a href="/screens">"See every screen →"</a></p>
        </section>
        <section class="features wrap section" id="features" aria-labelledby="features-title">
            <div class="section-heading"><p class="eyebrow">"LESS GUESSWORK"</p><h2 id="features-title">"Your localhost,"<br/>"with context."</h2><p>"The terminal that started it may be buried. The agent may be gone. See where a server belongs and make the next move from one place."</p></div>
            <div class="feature-list">
                <article><span class="feature-number">"01"</span><div><h3>"Find the project behind the port."</h3><p>"Working directory, git branch, worktree, framework, and uptime. Open the page or jump straight into the project."</p></div></article>
                <article><span class="feature-number">"02"</span><div><h3>"Keep track of your coding agents."</h3><p>"Trace a server to the agent that started it. Spot orphaned Claude Code servers when their launching session has ended."</p></div></article>
                <article><span class="feature-number">"03"</span><div><h3>"Catch checkout collisions."</h3><p>"See when independent agent sessions share a working tree. Parent sessions and their workers stay grouped."</p></div></article>
                <article><span class="feature-number">"04"</span><div><h3>"Clear the loose ends."</h3><p>"Stop one server, or use Flush to review orphaned servers and leftover development processes together. Active sessions and their checkouts stay protected; every signal gets a fresh identity check."</p><a class="text-link" href="/docs/menu-bar#flush" target="_self">"Review before you Flush →"</a></div></article>
            </div>
        </section>
        <section class="tools-section section" aria-labelledby="tools-title"><div class="wrap">
            <div class="tools-heading"><div><p class="eyebrow">"AT HOME IN YOUR WORKFLOW"</p><h2 id="tools-title">"From the menu bar"<br/>"to your next command."</h2></div><p>"Use the same detector from a terminal, a script, or an agent. No second inventory to keep in sync."</p></div>
            <div class="tools-grid">
                <article><div class="tool-meta"><span>"02 / COMMAND LINE"</span><span>"$"</span></div><h3>"Ask localhost a better question."</h3><CodeBlock label="List, inspect, wait" code="stillhere\nstillhere list --json\nstillhere sessions\nstillhere wait 5173"/><p>"Readable tables for you. Stable JSON for your scripts."</p><a class="text-link" href="/docs/cli">"Explore the CLI →"</a></article>
                <article><div class="tool-meta"><span>"03 / MCP"</span><span>"↔"</span></div><h3>"Let your agent see what it started."</h3><CodeBlock label="Connect Claude Code" code="claude mcp add --transport stdio --scope user stillhere -- stillhere mcp"/><p>"List servers and sessions, wait for an actual response, and check ownership before stopping a server."</p><a class="text-link" href="/docs/agents">"Connect your agent →"</a></article>
            </div>
        </div></section>
        <section class="privacy-strip wrap section" aria-labelledby="privacy-title"><span class="privacy-symbol" aria-hidden="true">"◎"</span><div><p class="eyebrow">"LOCAL BY DESIGN"</p><h2 id="privacy-title">"Your machine. Your business."</h2><p>"The app stays on your Mac. No telemetry. No account. Network requests go only to your local servers."</p><a class="text-link" href="/privacy">"Read the privacy details →"</a></div></section>
        <section class="download-section" id="download" aria-labelledby="download-title"><div class="wrap download-grid">
            <div><p class="eyebrow">"THE FIRST PUBLIC VERSION"</p><h2 id="download-title">"Make yourself"<br/>"at home on localhost."</h2><p>"Still Here v" {VERSION} " for Apple silicon Macs running macOS 26 or later."</p></div>
            <div class="download-card"><span class="release-label">"v" {VERSION}</span><h3>"Download for Mac"</h3><p>"A signed installer, notarized by Apple. Install the menu bar app and the stillhere command in one package."</p><a class="button" href=INSTALLER_URL target="_self">"Download v0.1.0 (.pkg)" <span aria-hidden="true">"↓"</span></a><a class="text-link" href="/docs/getting-started">"Installation and first run →"</a><a class="text-link" href="/docs/release">"What’s in v0.1.0 →"</a><p class="download-detail">"Menu bar app + CLI + MCP server"</p></div>
        </div></section>
    }
}
