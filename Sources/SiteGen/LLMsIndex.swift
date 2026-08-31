import Foundation

/// `/llms.txt` — a markdown index of the site, built from the same `SitePage` list as
/// the sitemap.
enum LLMsIndex {

    /// Grouping for the index, by slug so a retitled page keeps its place.
    private static let groups: [(heading: String, slugs: [String])] = Site.footerGroups.map {
        (heading: $0.heading, slugs: $0.links.map(\.path))
    }

    static func render(pages: [SitePage]) -> String {
        let bySlug = Dictionary(uniqueKeysWithValues: pages.map { ($0.slug, $0) })
        var out = """
            # DevDriveCacheClean (DDCC)

            > Free macOS disk cleanup for developers that reports what it found, what it \
            could not read, what each removal costs, and what its safety guard left in place.

            DDCC never asks the volume how much space is free. Every figure it reports is a \
            sum of files it can name and print a path for, which is why its total is usually \
            smaller than other cleaners' and why every byte in it can be checked \
            individually. Purgeable space, local snapshots and cloud placeholders are not \
            counted, because macOS already treats them as available. Content reachable by a \
            hard link from outside an item is not counted either, because removing the item \
            would not free it.

            Paths are attributed to an application only when something on the machine \
            declares the relationship — a sandbox container, a signed entitlement, a \
            Homebrew zap stanza, an installer receipt. Resemblance between a folder name \
            and an app name is never treated as evidence.

            Free to use, with no account, no telemetry and no network connection. \
            Source-available under the Sustainable Use License.

            """

        for group in groups {
            let entries = group.slugs.compactMap { bySlug[$0] }
            guard !entries.isEmpty else { continue }
            out += "\n## \(group.heading) (\(entries.count) pages)\n\n"
            for page in entries {
                out += "- [\(page.crumb ?? page.title)](\(page.canonical)): \(page.description)\n"
            }
        }

        // The guide is listed page by page: each page answers a separate question.
        let guide = pages
            .filter { $0.slug.hasPrefix(Site.guidePath) && $0.slug != Site.guidePath }
            .sorted { $0.slug < $1.slug }
        if let index = bySlug[Site.guidePath] {
            out += "\n## User Guide (\(guide.count + 1) pages)\n\n"
            out += "- [User Guide](\(index.canonical)): \(index.description)\n"
            for page in guide {
                out += "- [\(page.crumb ?? page.title)](\(page.canonical)): \(page.description)\n"
            }
        }

        return out
    }

    /// `/llms-full.txt` — the index, then every page's text, in the index's order, each
    /// headed by its canonical URL. Takes rendered HTML: a fragment still carries
    /// `{{…}}`.
    static func renderFull(pages: [SitePage], rendered: [String: String]) throws -> String {
        let bySlug = Dictionary(uniqueKeysWithValues: pages.map { ($0.slug, $0) })
        var ordered: [SitePage] = []
        if let front = bySlug[""] { ordered.append(front) }
        for group in groups {
            ordered += group.slugs.compactMap { bySlug[$0] }
        }
        if let index = bySlug[Site.guidePath] { ordered.append(index) }
        ordered += pages
            .filter { $0.slug.hasPrefix(Site.guidePath) && $0.slug != Site.guidePath }
            .sorted { $0.slug < $1.slug }

        // No `generated` timestamp: the built site is committed and compared
        // byte for byte, so a build clock fails `--check` on a clean checkout.
        var out = """
            ---
            title: DevDriveCacheClean (DDCC)
            alternate_names: [DDCC, DevDriveCacheClean]
            type: llms-full.txt (comprehensive site export)
            source_domain: \(URL(string: Site.origin)?.host() ?? Site.origin)
            canonical_index: \(Site.origin)/llms.txt
            page_count: \(pages.count)
            license_of_software: Sustainable Use License 1.0 (source-available, NOT OSI-approved open source)
            price: Free (USD 0), no paid tier, no trial
            platform: macOS 15+, Apple silicon and Intel
            maker: \(Site.developer)
            repository: \(Site.repository)
            ---

            \(Site.canonicalDefinition)

            """

        out += "\n" + render(pages: pages)
        out += "\n---\n"

        for page in ordered {
            guard let html = rendered[page.slug] else {
                throw SiteError.missingRendering(page.slug)
            }
            out += "\n# \(page.crumb ?? page.title)\n\n"
            out += "Source: \(page.canonical)\n\n"
            out += try PlainText.markdown(from: html)
            out += "\n\n---\n"
        }
        return out
    }
}
