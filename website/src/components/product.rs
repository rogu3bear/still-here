use leptos::prelude::*;

pub const SOURCE_URL: &str = "https://github.com/rogu3bear/still-here";

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[component]
pub fn Brand() -> impl IntoView {
    view! { <img class="brand-mark" src="/images/app-icon.png" alt="" width="25" height="25"/><span>"Still Here"</span> }
}

#[component]
pub fn CodeBlock(#[prop(into)] code: String, #[prop(into)] label: String) -> impl IntoView {
    view! { <div class="code-block"><div class="code-label">{label}</div><pre><code>{code}</code></pre></div> }
}

#[component]
pub fn NativeScreen(
    #[prop(into)] src: String,
    #[prop(into)] label: String,
    #[prop(into)] description: String,
    width: u32,
    height: u32,
) -> impl IntoView {
    let path = format!("/images/{src}");
    let open_label = format!("Open full-resolution {description}");
    view! {
        <figure class="native-screen">
            <figcaption><span>{label}</span><p>{description.clone()}</p></figcaption>
            <a class="screen-image" href=path.clone() target="_self" aria-label=open_label>
                <img src=path.clone() alt=description.clone() width=width height=height loading="lazy"/>
            </a>
            <a class="screen-open" href=path.clone() target="_self">"Open original capture ↗"</a>
        </figure>
    }
}
