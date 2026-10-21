use super::docs_layout::DocsLayout;
use super::product::{CodeBlock, SOURCE_URL};
use leptos::prelude::*;
use leptos_meta::Title;

#[component]
pub fn GettingStartedPage() -> impl IntoView {
    view! {
        <Title text="Getting started — Still Here"/>
        <DocsLayout active="start">
            <p class="eyebrow">"GETTING STARTED"</p><h1>"Your first clear"<br/>"look at localhost."</h1>
            <p class="doc-lead">"Open the menu, find a server you recognize, and follow it back to its project. You don’t have to connect an agent or change your workflow to use Still Here."</p>
            <section id="requirements"><h2>"Requirements"</h2><ul><li>"An Apple silicon Mac (arm64)."</li><li>"macOS 26 or later."</li><li>"For a source build: Xcode 26 or later with Swift 6.2 or later."</li></ul></section>
            <section id="install"><h2>"Public installer"</h2><p>"The first public version is v0.1.0. Its signed, notarized installer is in preparation; there is no public download on this site yet."</p><p>"The intended package installs /Applications/Still Here.app and links /usr/local/bin/stillhere. Once available, open the installed app from Applications. It lives in the menu bar with no Dock icon."</p><a class="text-link" href="/docs/release">"v0.1.0 release details →"</a></section>
            <section id="source"><h2>"Run from source"</h2><a class="text-link" href=SOURCE_URL target="_blank" rel="noopener noreferrer">"Source on GitHub ↗"</a><p>"Still Here is open source under GPLv3. Clone the repository and build it on your Mac with Python 3.11 or later for build maintenance. The development bundle is signed for local use and is not a public distribution package."</p><CodeBlock label="Build Still Here" code="git clone https://github.com/rogu3bear/still-here.git\ncd still-here\npython3 -B scripts/build.py swift build\npython3 -B scripts/build.py swift test\nscripts/bundle.sh --dev\nopen \"build/Still Here.app\""/><p>"A source build does not install a global command. Run its CLI directly:"</p><CodeBlock label="Check the CLI" code=".build/debug/stillhere version\n.build/debug/stillhere\n.build/debug/stillhere help"/></section>
            <section id="first-look"><h2>"Take a first look"</h2><ol class="doc-steps"><li>"Start a dev server in a project using your usual command."</li><li>"Click the Still Here menu bar icon. Its number shows visible servers; the menu refreshes when you open it."</li><li>"Find your project and port. Open the page or use Reveal to check the folder."</li><li>"When you finish, choose Stop on that server and confirm. Read the result rather than assuming the port is now free."</li></ol><p>"With no visible servers, the list is empty. If an expected server is missing, turn on Show hidden servers in General Settings."</p><a class="text-link" href="/docs/menu-bar">"Read the menu and its controls →"</a></section>
            <section id="login"><h2>"Keep it nearby"</h2><p>"Launch at login is optional. Enable it from a copy installed in /Applications, then approve it in macOS Login Items if requested. Avoid registering a temporary build-directory copy."</p><p>"Use Quit in the menu to exit. Quitting Still Here leaves your dev servers running."</p></section>
            <section id="upgrade"><h2>"Upgrading later"</h2><p>"Install the newer package, then Quit and reopen the menu bar app. The CLI uses the replacement binary immediately; a running menu bar process keeps its old version until relaunched."</p><a class="text-link" href="/docs/agents">"Next: connect a coding agent →"</a></section>
        </DocsLayout>
    }
}
