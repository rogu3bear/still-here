# Still Here visual direction

The selected authority is the operator's explicit request to reproduce the
[original monochrome Refero reference](https://styles.refero.design/style/f24daf3a-d43f-4dec-85a9-8ac1d5148a03).
The reference screen is a 1600×1000 capture with a compact left-aligned two-line
headline, a centered product subject, right-aligned uppercase mono annotations,
a narrow header, and generous unbroken white space. Keep Still Here's own brand,
content, routes, and actual app identity. Cloudflare hosting is independent of
the reference's brand; publication uses cfctl.

Use self-hosted Geist Sans and Geist Mono 1.7.2 from the official `geist` package,
with its bundled SIL Open Font License. Canvas `#fafafa`, elevated surface
`#ffffff`, ink `#171717`, body `#4d4d4d`, muted `#666666`, and rule `#ebebeb`.
Display weights are 450, tight tracking is -0.06em, labels use 0.071em tracking,
rectangular cards use 6px radius, and hero actions use compact pill shapes.
The app icon and screenshots retain their actual native colors.

After inspecting the first implementation, the operator called out its awkward
empty hero. Keep the reference's three-column rhythm, but use the original menu
capture as the central subject, add a short product description, and reduce the
hero's empty vertical space. The actual interface must appear in the first
desktop screen. On narrow screens, stack the copy, complete capture, and notes;
never crop the native controls to fit the layout.

The site's exact-screen gallery lives at `/screens`. Menu, dark menu, Stop
confirmation, and Flush review and result are rendered from the shipped SwiftUI views with inert sample
projects, a fixed clock, and original controls. General, Ignore List, and About
are captured from the displayed native windows using CUA; do not substitute
off-screen approximations of system chrome. Images open at original resolution.
Screens are never redrawn as HTML or AI-generated images. The Ignore List
capture shows its original scroll position; it does not pretend all rules fit
in one window.

Responsive widths include mobile, intermediate, XL 1280px, XXL 1536px, and XXXL
1920px. Keep readable body measures and a bounded large-screen composition.
Native controls belong to the original app; website framing stays separate.
