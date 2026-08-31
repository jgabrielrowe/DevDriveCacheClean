import Foundation
import HelpBookGen

/// The licence page, rendered from LICENSE.md by `MarkdownSubset`.
public enum LicencePage {

    public static func page(licenceURL: URL) throws -> SitePage {
        let markdown = try String(contentsOf: licenceURL, encoding: .utf8)
        let article = try MarkdownSubset.html(from: markdown)

        return SitePage(
            slug: "licence/",
            title: "Licence — DDCC",
            description: """
                Source-available under the Sustainable Use License: personal and internal \
                business use are royalty-free; commercial redistribution needs an arrangement.
                """,
            kind: .marketing,
            body: """
                <main>
                <div class="wrap">
                  <div class="legal">
                    {{crumb}}
                    <article>
                \(indent(article, by: 4))
                    </article>
                  </div>
                </div>
                </main>
                """,
            crumb: "Licence")
    }
}
