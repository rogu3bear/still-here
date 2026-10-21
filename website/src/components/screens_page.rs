use super::product::NativeScreen;
use leptos::prelude::*;
use leptos_meta::Title;

#[component]
pub fn ScreensPage() -> impl IntoView {
    view! {
        <Title text="The app, in full — Still Here"/>
        <div class="screens-page wrap">
            <p class="eyebrow">"THE NATIVE APP / v0.1.0"</p>
            <h1>"The app, in full."</h1>
            <p class="screens-intro">"The actual SwiftUI and AppKit views used by Still Here. Original captures, with their native controls, labels, and colors. Sample projects keep private work out of the pictures."</p>
            <div class="screens-grid">
                <NativeScreen src="menu-bar.png" label="01 / MENU BAR · LIGHT" description="Servers, branches, agents, and checkout collisions." width=800 height=712/>
                <NativeScreen src="menu-bar-dark.png" label="02 / MENU BAR · DARK" description="The same menu in the native macOS dark appearance." width=800 height=712/>
                <NativeScreen src="settings.jpg" label="03 / GENERAL SETTINGS" description="Refresh timing, HTTP checks, terminal choice, and launch at login." width=960 height=1104/>
                <NativeScreen src="ignore-list.jpg" label="04 / IGNORE LIST" description="The real Ignore List tab with native hide rules and process exclusions." width=960 height=1104/>
                <NativeScreen src="stop-confirmation.png" label="05 / STOP CONFIRMATION" description="The original inline confirmation before sending SIGTERM." width=800 height=800/>
                <NativeScreen src="flush-review.png" label="06 / FLUSH REVIEW" description="The proposed orphaned or detached development processes, reviewed before cleanup." width=800 height=1050/>
                <NativeScreen src="flush-review-dark.png" label="07 / FLUSH REVIEW · DARK" description="The same review in the native macOS dark appearance." width=800 height=1050/>
                <NativeScreen src="flush-result.png" label="08 / FLUSH RESULT" description="Separate counts for stopped, preserved, and unresolved processes." width=800 height=844/>
                <NativeScreen src="about.jpg" label="09 / ABOUT" description="The standard macOS About panel with the real app icon and v0.1.0." width=568 height=454/>
            </div>
            <p class="capture-note">"Each image opens at its original resolution. These are native app captures, with inert sample data and actions. "<a href="/docs">"Read the guide →"</a></p>
        </div>
    }
}
