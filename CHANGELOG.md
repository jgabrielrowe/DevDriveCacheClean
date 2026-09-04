# Changelog

Notable changes to DevDriveCacheClean. Dates are the release date, and version
numbers follow the tag on the release page.

Sizes and contrast ratios in this file were measured on real machines rather
than estimated, which is the same standard the app applies to what it reports.

## 1.0.1 — 2026-09-03

The first release after 1.0.0 reached people other than its author. Almost
everything here comes from that: an Intel Mac in light appearance, and a
machine with Android Studio on it.

### Readability

- **Secondary text is legible in light appearance.** The line under each row —
  the category under a path, the evidence under an app name, the counts in the
  sidebar — was rendering at 1.88:1 against the window background, where the
  accessibility standard for text that size asks 4.5:1. It is 4.77:1 now.
  Reported by a user in light appearance; it had gone unnoticed because it
  measures 2.26:1 in dark, which is bad but readable.
- **The same text is lighter in dark appearance**, 2.26:1 to 4.63:1. The two
  appearances use different values to land on the same contrast, because they
  sit on different backgrounds.
- **It is also a point larger**, 10pt to 11pt. On macOS `footnote`, `caption`
  and `caption2` are all 10pt, so the obvious change would have moved nothing.
- **Sidebar group headings are larger and darker.** They were smaller than the
  rows beneath them and, in dark appearance, dimmer as well.

### Accessibility

- **The three controls on each result row have names.** Select, the locked
  category control and the opt-in control were buttons whose entire label was
  an icon, so VoiceOver announced "button" and no more. Each now says what it
  acts on and what state it is in.
- **Decorative icons are silent.** Five glyphs that sat immediately before text
  saying the same thing are hidden from VoiceOver rather than announced twice.
- The app contains **no fixed font size**, so every string follows the system
  text size setting.

### The sidebar

- **Three rows are announced as three.** Caches, Files and Uninstall sat inside
  a group that drew nothing on screen but still counted, so VoiceOver said
  "row 2 of 4" over three visible rows and named the wrong one.
- **Each row's icon sits level with its name.** The icon was centred against
  the name and the figures beneath it together, which left it floating between
  the two lines rather than beside the word it labels.

### Android

- **New Android category**, covering SDK platforms, sources, build tools and
  emulator system images, each listed per version.
- **Build tools follow the version-manager rule**: the newest is never offered,
  because Gradle uses it unless a project pins another.
- **The emulator, platform tools and licences are never listed.** The emulator
  is the single largest directory in the SDK at 1.2 GB, and removing any of the
  three breaks the SDK rather than freeing a stale copy.
- **Virtual devices are tier 3.** An emulator holds the apps installed inside
  it; recreating the device does not bring them back.
- **Uninstalling Android Studio now takes the SDK with it** — about 2.0 GB that
  no source claimed before. `~/.android` is deliberately left behind: it holds
  this machine's ADB identity, and removing it makes every physical device
  authorise again.

### Website

- **Contrast meets WCAG 2.1 AA.** The footer's legal links, breadcrumbs, tier
  labels and page navigation were at 2.76:1.
- **A skip link on every page.** Each page repeats a seven-item masthead, and
  the guide pages add a sixteen-item rail, with no way past either.
- **A main landmark on every page.** Sixteen had none — every user-guide and
  reference page, which are the pages read at length.
- **Tablet widths are fixed.** Between 1181px and 1320px the documentation rail
  appeared before there was room for it, cutting the reading column from about
  830px to about 530px: the page read worse the wider the window got.
- **The navigation menu says what it is and whether it is open.** On narrow
  screens the menu opens from a checkbox, so a screen reader announced an
  unnamed control as "checked" or "unchecked" — the vocabulary of a form
  control rather than of a menu. It is now named, and reports collapsed or
  expanded.
- **Above 860px that control leaves the tab order.** The burger is not drawn at
  desktop widths, but its checkbox stayed focusable, so tabbing the masthead
  stopped on nothing between the wordmark and the first link. It is invisible
  in the markup and invisible on screen; only a keyboard finds it.

### Internal

- Removed three declarations nothing called, including one whose comment
  described wiring that did not exist.

## 1.0.0 — 2026-08-31

First public release. Universal, signed with a Developer ID, notarised and
stapled, so a first launch works without a network.

- Scans developer caches, large files and installed application footprints.
- Every result names the tool that created it and the tier it sits in.
- Three tiers by what removal costs: rebuilt on demand, comes back slowly, does
  not come back. Costly categories start locked, destructive items are opted in
  one at a time.
- Removals go to the Trash by default.
- Reports what it could not read rather than hiding it, and marks affected
  totals as undercounts.
- No account, no telemetry, no network connections.
