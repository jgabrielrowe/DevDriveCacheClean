import Foundation

/// The schema.org blocks the site emits, derived from data the generator already holds.
public enum StructuredData {

    public enum Error: Swift.Error {
        case notSerialisable(keys: [String])
    }

    /// Compact JSON. `sortedKeys` keeps bytes stable between runs, which the drift
    /// check requires.
    static func json(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw Error.notSerialisable(keys: object.keys.sorted())
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func script(_ object: [String: Any]) throws -> String {
        "<script type=\"application/ld+json\">\n\(try json(object))\n</script>"
    }

    // MARK: - Breadcrumbs

    /// The page's trail, derived from slug, kind and crumb. Two shapes: DDCC / leaf,
    /// and DDCC / User Guide / leaf. `nil` for the front page and the 404, matching
    /// `Shell.crumbHTML`.
    static func breadcrumb(for page: SitePage) -> [String: Any]? {
        guard let leaf = page.crumb, !page.slug.isEmpty, !page.isFile else { return nil }

        var trail: [(name: String, url: String)] = [("DDCC", "\(Site.origin)/")]
        if page.kind == .documentation {
            trail.append(("User Guide", "\(Site.origin)/\(Site.guidePath)"))
        }
        trail.append((leaf, page.canonical))

        return [
            "@context": "https://schema.org",
            "@type": "BreadcrumbList",
            "itemListElement": trail.enumerated().map { index, step in
                [
                    "@type": "ListItem",
                    "position": index + 1,
                    "name": step.name,
                    "item": step.url,
                ] as [String: Any]
            },
        ]
    }

    // MARK: - The application itself

    /// The SoftwareApplication block, emitted on the front and download pages.
    static var application: [String: Any] {
        [
            "@context": "https://schema.org",
            "@type": "SoftwareApplication",
            // Shared @id, so the two pages describe one application rather than two.
            "@id": "\(Site.origin)/#app",
            "name": "DevDriveCacheClean",
            "alternateName": "DDCC",
            "applicationCategory": "UtilitiesApplication",
            "operatingSystem": "macOS 15 or later",
            "processorRequirements": "Apple silicon or Intel",
            "url": "\(Site.origin)/",
            "downloadUrl": "\(Site.origin)/download/",
            "isAccessibleForFree": true,
            "author": ["@id": "\(Site.origin)/#developer"],
            "creator": ["@id": "\(Site.origin)/#developer"],
            // A URL, not a name: SUL-1.0 has no SPDX identifier to resolve.
            "license": "\(Site.origin)/licence/",
            "sameAs": [Site.repository, Site.donationURL],
            // No softwareVersion or availability until there is a release to describe.
            "offers": [
                "@type": "Offer",
                "price": "0",
                "priceCurrency": "USD",
            ],
            "description": Site.canonicalDefinition,
        ]
    }

    // MARK: - Who made it

    /// The developer, as an entity the application's claims hang off. Referenced
    /// by `@id` so two pages name one person rather than asserting two.
    static var developer: [String: Any] {
        [
            "@context": "https://schema.org",
            "@type": "Person",
            "@id": "\(Site.origin)/#developer",
            "name": Site.developer,
            "url": "\(Site.origin)/",
            "sameAs": Site.developerProfiles,
        ]
    }

    // MARK: - The site as a named thing

    /// The WebSite block. Emitted on the front page only; it is ignored elsewhere.
    static var website: [String: Any] {
        [
            "@context": "https://schema.org",
            "@type": "WebSite",
            "@id": "\(Site.origin)/#website",
            "name": "DevDriveCacheClean",
            "alternateName": "DDCC",
            "url": "\(Site.origin)/",
            "publisher": ["@id": "\(Site.origin)/#developer"],
        ]
    }
}
