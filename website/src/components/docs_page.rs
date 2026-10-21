use super::docs_layout::DocsLayout;
use super::product::CodeBlock;
use leptos::prelude::*;
use leptos_meta::Title;

#[component]
pub fn DocsPage() -> impl IntoView {
    view! {
        <Title text="Why Still Here — The guide"/>
        <DocsLayout active="overview">
            <p class="eyebrow">"A LITTLE CLARITY FOR LOCALHOST"</p>
            <h1>"What’s running?"<br/>"Now you know."</h1>
            <p class="doc-lead">"A few terminals, a few agents, a few projects. Before long, something is still running and you can’t remember where it came from. Still Here gives you one place to see it, find its project, and stop it when you’re done."</p>
            <section><h2>"From a mystery port to a clear decision"</h2>
                <ol class="doc-steps">
                    <li><strong>"Find it."</strong>" Open the menu bar to see local servers running under your user, with their ports, URLs, and current HTTP status."</li>
                    <li><strong>"Understand it."</strong>" Check the project, branch or worktree, uptime, and agent when attribution is available. Open the page, reveal the folder, or jump into its terminal."</li>
                    <li><strong>"Take it out."</strong>" If you no longer need that server, choose Stop and confirm the process. Still Here verifies its identity before signalling it, then refreshes the list."</li>
                </ol>
                <a class="text-link" href="/docs/menu-bar#stop" target="_self">"How stopping works →"</a>
            </section>
            <section><h2>"The moments it earns its place"</h2>
                <dl class="doc-definitions">
                    <div><dt>"“Why is port 3000 busy?”"</dt><dd>"See the project already using it. Decide whether to keep that server or stop it before starting another."</dd></div>
                    <div><dt>"“Which preview am I looking at?”"</dt><dd>"Match the URL to a branch and worktree. Open the right checkout instead of guessing from an old browser tab."</dd></div>
                    <div><dt>"“The agent finished. What did it leave behind?”"</dt><dd>"Look for servers with a known launcher that has ended. An orphan label gives you something specific to review and clean up."</dd></div>
                    <div><dt>"“Are these agents in the same checkout?”"</dt><dd>"Inspect the sessions list and its collision warnings before independent sessions overwrite each other’s work."</dd></div>
                </dl>
            </section>
            <section id="install"><h2>"Start with the menu bar"</h2><p>"Still Here runs on Apple silicon Macs with macOS 26 or later. The v0.1.0 public installer is in preparation. If you have repository access, you can build and run it locally today."</p><a class="text-link" href="/docs/getting-started">"Getting started →"</a></section>
            <section id="cli"><h2>"Use the same view from a terminal"</h2><CodeBlock label="Inspect first" code="stillhere\nstillhere sessions\nstillhere list --orphans"/><p>"The menu, CLI, and MCP server share the detector and your saved ignore list. Use tables when exploring and JSON when scripting."</p><a class="text-link" href="/docs/cli">"Complete command reference →"</a></section>
            <section id="mcp"><h2>"Give your agent the same context"</h2><p>"An agent can list servers, inspect sessions, wait for a preview to answer, and stop a server. A supported session’s ownership is checked before an ordinary MCP stop."</p><a class="text-link" href="/docs/agents#mcp" target="_self">"Connect Claude Code or Codex →"</a></section>
            <section id="collisions"><h2>"Get a heads-up before editing"</h2><p>"The Claude Code SessionStart hook can tell a session when another independent writer is already in its checkout. It adds context; it does not lock the repository or prevent edits."</p><a class="text-link" href="/docs/agents#collisions" target="_self">"Set up the collision hook →"</a></section>
            <section id="limits"><h2>"Know what the labels mean"</h2><p>"Framework names are informed guesses. Missing agent attribution means unknown. Orphaned means a known launcher has ended; it does not mean the server is safe to discard. The Codex desktop app’s chats share one host process, so collisions between those chats are not detectable."</p><p>"Still Here observes local processes owned by your user. It does not inspect remote servers, containers on another machine, planned file edits, or application-level correctness."</p><a class="text-link" href="/docs/troubleshooting#limits" target="_self">"Detection limits and common questions →"</a></section>
        </DocsLayout>
    }
}
