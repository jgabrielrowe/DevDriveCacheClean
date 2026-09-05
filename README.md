# DevDriveCacheClean

**DDCC** is a macOS disk cleanup tool for developers. It finds developer caches, app caches, build artifacts, large old files, and bundles; explains what each item is; and removes only what you explicitly choose.

DDCC is built around practical safety rules: scan locally, show partial sizes as floors, never preselect risky items, move ordinary files to the Trash, and require extra confirmation before permanent cache deletion.

Requires **macOS 15 or later**. Source-available under [SUL-1.0](LICENSE.md).

---

## Contents

- [Install](#install) · [First scan](#first-scan)
- [How cleanup decisions work](#how-cleanup-decisions-work)
- [Caches](#caches) · [Files](#files) · [Uninstall](#uninstall) · [Privacy](#privacy)
- [Help](#help) · [Full Disk Access](#full-disk-access)
- [What it will not do](#what-it-will-not-do)
- [Project layout](#project-layout) · [Tests](#tests) · [License](#license)

---

## Install

No release binaries are published yet. Build it locally:

```sh
git clone https://github.com/jgabrielrowe/drive-clean.git
cd drive-clean
swift build                  # libraries and executable
swift test
Scripts/make-app.sh --install  # assemble DDCC.app and place it in /Applications
```

`make-app.sh` builds a release binary, assembles the bundle, generates the help book and its search index, signs the result, and verifies the parts of the bundle macOS fails silently on. Drop `--install` to leave `DDCC.app` in the working directory.

Builds are **ad-hoc signed by default**, so a fresh clone needs no setup. `Scripts/create-signing-cert.sh` and `Scripts/signing.local.sh` cover signing with a real identity.

The installer refuses to overwrite a copy that is currently running, because replacing a live bundle corrupts the running process. Quit DDCC first.

## First scan

Launch DDCC and press **Scan** in the Caches view. It walks your home directory by default; use **Scan Path** to scan another folder.

Nothing is selected when the scan finishes. Review the results, unlock any categories you are comfortable removing, pick the rows you want, then press **Delete**. The confirmation sheet lists exactly what will go. It moves items to the **Trash** by default; permanent cache deletion is a separate, explicit opt-in.

Use **Files** for large, long-unmodified files and bundles outside `~/Library`. Files results are never selected automatically and are always moved to the Trash rather than deleted permanently.

## How cleanup decisions work

Every candidate carries a **tier**, which answers one question: what does it cost you if the classification was wrong?

| Tier | Meaning | How you select it |
|---|---|---|
| **Safe** | Rebuilt by one command from a file in your project. | In bulk. |
| **Costly** | Shared across every project. Comes back, but costs time and bandwidth. | Unlocks per category, for one scan, after you acknowledge what that category holds. |
| **Destructive** | Cannot be recovered, or takes hours to rebuild by hand. | One item at a time. No bulk action can reach it. |

Tiers measure **blast radius, not download size**. A 4 GB re-download that one command restores can be `safe`; a 2 KB file nothing can reproduce is `destructive`. Where two rules disagree about a path, the more cautious one wins.

Separately from tier, each item carries a **removability** state:

- Selectable items can be removed.
- Locked items are costly categories that must be unlocked for the current scan.
- Warning items are destructive and must be selected one at a time.
- Privileged or informational items are shown for size accounting but cannot be selected.

Sizes marked with `+` are lower bounds. DDCC could read enough to know the item is at least that large, but not enough to measure the full size.

## Caches

22 curated categories, 14 of them developer-specific.

**Developer** — Node.js · Python · Rust · Java/Kotlin · Xcode · Go · Docker · Homebrew · Package Caches · IDE & Editor · macOS Dev Caches · Terraform · Web Frameworks · Build Output

**System & Apps** — App Caches · Browser Data · iOS Backups · Saved App State · Mail Downloads · System Caches · Logs & Crashes · App Deep Clean

Node.js and Python also cover installed toolchain versions — `~/.nvm/versions/node`, `~/.pyenv/versions` — which a version manager keeps forever and never removes. The version you are on is never offered: DDCC holds back the newest, whichever the manager's own alias points at, and any version something is currently running from.

The toolbar lets you scan, scan a specific path, select Tier 1 safe results, unlock Tier 2 categories, deselect everything, delete selected rows, and sort the result list. Sidebar totals include visible results plus locked or informational bytes that DDCC can measure but should not remove automatically.

## Files

The Caches view only reports what a pattern recognises. **Files** covers the rest: large, long-unmodified files and bundles outside `~/Library` — the things no rule vouches for.

Filter by minimum size and by how long a file has gone unmodified. "Unmodified" means the file has not been edited, not that it has not been opened. The space bar previews the selected row through QuickLook, the same gesture as Finder.

Because nothing vouches for these files, the Files view **moves them to the Trash and never deletes them permanently.** Its skip list is derived from the Caches profile rather than written separately, so the two views cannot report the same bytes twice.

Packages and bundles, including `.app` and `.photoslibrary` items, are treated as single files. If you move one to the Trash, the whole bundle moves.

## Uninstall

Uninstall lists every app identity on the machine — installed, or already gone — with the footprint DDCC can actually attribute to it: sandbox containers, bundle-id-keyed shelves (Preferences, Caches, Saved Application State and more), `application-groups` entitlements, Homebrew's local `zap` declarations, install receipts, and native-messaging-host manifests whose declared target resolves inside the app. Nothing is inferred from a directory's name. A broken dependency pointer — a manifest or launch agent naming a file that no longer exists — is the one signal DDCC treats as proof an artifact is dead on its own, independent of any app, and it gets its own row.

Each row separates what it can reclaim from what another installed product still claims. A shared resource stays retained, its bytes excluded from the reclaimable total, until the last claimant is gone. What sits outside DDCC's allowed folders, or inside them but refused anyway by the same safety check every other removal goes through, is listed by path and counted, not hidden. Below the list, DDCC states which evidence sources were unavailable for the sweep and how many bytes it found but could attribute to no app.

Uninstall removes the application itself along with its leftovers, in one action. An app installed for all users by a `.pkg` — Microsoft Office and many others — is owned by `root`, and macOS refuses to let an ordinary user move it to the Trash whatever the folder's permissions allow. For those, DDCC asks Finder to perform the move, so macOS prompts for Touch ID or an admin password and Apple's own code does the privileged step. Such an app can only be moved to the Trash, never deleted permanently, and the confirmation says so rather than skipping it silently.

An app that is currently running is listed with its refusal stated, and offers Quit and Force Quit, because that is the one refusal you can clear yourself. Nothing about a running app is measured: a live process rewrites the files being counted.

Uninstall reuses `PathGuard`, `DeletionService` and `SizeCalculator` unchanged from the Caches pipeline — the two components that actually protect a deletion are shared, not reimplemented. It moves items to the Trash by default; permanent removal is a separate, explicit opt-in with its own confirmation, because an uninstall has a far higher cost of being wrong than a cache sweep and is the one action in the tool with no undo.

Every evidence source it reads is a local file: the Homebrew cask cache, receipt plists and their BOMs, and entitlements read in-process via Security.framework. Nothing in the sweep makes a network connection or runs a subprocess.

```sh
grep -rE 'Process\(|URLSession|launchPath' Sources/DDCCCore/Uninstall/
```

DDCC spawns exactly one subprocess anywhere, and only when you remove an app owned by `root`: `/usr/bin/osascript`, to ask Finder to move that one app to the Trash. It runs nowhere else.

```sh
grep -rn 'Process(' Sources/DDCCCore/
```

Uninstall does not attempt the wider sweep of every unattributed byte on a shelf, and does not yet attribute login items or privileged helpers.

## Privacy

DDCC does not talk to the network.

```sh
grep -rE 'URLSession|import Network|https?://|CFNetwork|getaddrinfo' Sources/
```

There is no analytics, telemetry, update check, crash reporting, account, or remote classification. Scanning uses local file metadata such as names, sizes, and dates. The Full Disk Access probe is the only place DDCC opens a file for access detection; it reads a single byte from a known protected path to check whether permission was granted.

DDCC also has no third-party dependencies.

```sh
grep -n '\.package(url:' Package.swift
find . -name Package.resolved -not -path '*/.build/*'
grep -rhoE '^import [A-Za-z_]+' Sources/ | sort -u
```

`Package.swift` declares no external packages, there is no `Package.resolved` in the repo, and every `import` in `Sources/` is either an Apple system framework (`AppKit`, `Darwin`, `Foundation`, `os`, `QuickLookUI`, `Security`, `SwiftUI`) or a DDCC module (`DDCCCore`, `DDCCUI`, `HelpBookGen`). For a tool that asks for Full Disk Access and deletes files, that means there is no third-party code between the source you can read and the binary that runs.

## Help

DDCC ships a native Apple Help Book: **Help → DDCC Help**, or `⌘?`. It is searchable from the menu bar as well as inside Help Viewer, it carries a topics column on every page, and it explains the tiers, every category, and what the app can and cannot remove.

Category and tier explanations in the book are drawn from the same catalogue as the tooltips. A new category cannot compile without help text, so the in-app explanations stay tied to the scanner.

## Full Disk Access

Optional. The app probes for it and shows an advisory banner when it is missing.

DDCC targets developer caches that any app can usually read. Granting Full Disk Access can make protected folders measurable and may remove `+` markers from some sizes, but scans still run without it. On one development machine, granting access changed the scan total from 3,601 items to 3,603 while total size stayed at 60.59 GB; your system will differ.

## What it will not do

Some cleaner-style features are deliberately absent:

- **Memory "optimization."** On macOS, free RAM is wasted RAM. Purging it makes the machine slower.
- **Malware removal.** macOS ships XProtect, and DDCC is not an antivirus tool.
- **App updating.** Homebrew, the App Store and Sparkle already do this.
- **Counting caches that regenerate in minutes as durable recovered space.** DDCC reports what it can remove, but short-lived caches may come back quickly.


## Project layout

| Path | What lives there |
|---|---|
| `Sources/DDCCCore` | Scanning, classification, tiers, path safety. No UI. |
| `Sources/DDCCUI` | SwiftUI views and view models. |
| `Sources/DevDriveCacheClean` | The app entry point. |
| `Sources/HelpBookGen` · `HelpBookBuilder` | Turns `Help/*.md` into the Apple Help Book and its index. |
| `Help/pages` · `Help/generated` | Help content: authored prose, and reference pages generated from the catalogue. |
| `Scripts/` | Bundle assembly, icon generation, signing. |
| `docs/` | Roadmap, known gaps, and the design specs behind each feature. |

## Tests

```sh
swift test
```

Two conventions matter more than the count.

**A test that cannot fail is treated as a defect, not as coverage.** Guards against vacuous passes are written explicitly, and new assertions are checked by breaking the code and confirming the test notices.

**Failures macOS reports silently are checked at build time.** A help book whose title disagrees with the app's can open as an empty window; a stale search index can answer wrong; a missing icon can fall back silently. `make-app.sh` verifies these bundle details.


## License

DevDriveCacheClean (DDCC) is source-available software licensed under the Sustainable Use License Version 1.0 (`SUL-1.0`).

In practical terms, you may:

- Use DDCC for personal purposes.
- Use DDCC for non-commercial purposes.
- Use DDCC internally at a business or other organization.
- Inspect and study the source code.
- Modify DDCC for permitted uses.
- Redistribute DDCC or modified versions free of charge for non-commercial purposes.

You may not redistribute DDCC, or a modified version of DDCC, for commercial purposes, or charge others for copies of the software.

If you pass DDCC on to anyone, you must give them a copy of the license terms as well. Modified copies must carry a prominent notice stating that they have been modified, and the license, copyright and other notices included with DDCC must be preserved.

See [LICENSE.md](LICENSE.md) for the complete legally controlling terms, and [NOTICE.md](NOTICE.md) for the copyright notice.

### Source-available, not OSI open source

DDCC is intentionally source-available rather than distributed under an OSI-approved open-source license, because SUL-1.0 restricts commercial redistribution. GitHub reports the license as unrecognized, because SUL has no SPDX identifier of its own. Calling DDCC "open source" would be inaccurate; "source-available" is the correct term.

### Commercial licensing

SUL-1.0 does not grant permission to commercially redistribute DDCC or derivative versions.

If you have a commercial use case that SUL-1.0 does not permit, email support@devdrivecacheclean.com about a separate commercial license.

### Branding

The software license does not grant permission to use the DevDriveCacheClean name, application icon, logo, or other project branding in a way that suggests an unofficial version is an official DDCC release.

A fork must also ship under its own bundle identifier: macOS keys Full Disk Access to it, so a fork sharing the official identifier interferes with the official application's permissions. `Scripts/make-app.sh` reads a `DDCC_BUNDLE_ID` override for exactly this.

See [TRADEMARKS.md](TRADEMARKS.md).

### Contributing

Bug reports, tests, documentation and code contributions are welcome. Contributions require agreement to the [Contributor License Agreement](CLA.md) — see [CONTRIBUTING.md](CONTRIBUTING.md).
