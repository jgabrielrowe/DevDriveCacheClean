import Foundation

/// The FAQ, written once. The visible cards and the FAQPage block are both rendered
/// from `entries`; Google requires the markup to match the visible text.
public enum FAQ {

    public struct Entry: Sendable {
        /// The eyebrow above the question. Presentation only; not carried into the
        /// structured data.
        public let tag: String
        public let question: String
        public let answer: String

        public init(tag: String, question: String, answer: String) {
            self.tag = tag
            self.question = question
            self.answer = answer
        }
    }

    /// Order is the reading order on the page, grouped by `tag`.
    public static let entries: [Entry] = [
        Entry(tag: "MONEY",
              question: "Is it really free?",
              answer: "Yes, permanently. No paid tier, no trial, no licence key, nothing held back. The scan and the removal are the same free program."),
        Entry(tag: "PRIVACY",
              question: "Does it connect to the internet?",
              answer: "DDCC is built without account sign-in, telemetry or network features. The only program it launches is Finder, and only to finish a removal you chose. You can verify that by reading the source or by watching it with Little Snitch."),
        Entry(tag: "PRIVACY",
              question: "Does it install a launch agent or daemon?",
              answer: "No. Nothing of DDCC's runs when the app is closed: no launch agent, no daemon, no login item, no background helper. Check it yourself before and after use \u{2014} nothing of DDCC's appears in ~/Library/LaunchAgents or /Library/LaunchDaemons, and the app bundle contains no helper to install."),
        Entry(tag: "TOTALS",
              question: "Why do Mac cleaners disagree about free space?",
              answer: "Because they count different things: whether to include purgeable space macOS already treats as available, whether bytes reachable under two names count once or twice, and whether a folder that could not be read counts as zero. DDCC counts files it can name, counts a shared byte once, and says what it could not read."),
        Entry(tag: "TOTALS",
              question: "Why is your number smaller than the others?",
              answer: "Because it excludes space macOS already manages. Purgeable storage, local snapshots and cloud placeholders are not counted as removable DDCC findings."),
        Entry(tag: "TOTALS",
              question: "What does the plus sign mean?",
              answer: "At least. Some folder could not be read, so the figure is a floor rather than a total. The app says how many and why."),
        Entry(tag: "SAFETY",
              question: "Could it delete something I needed?",
              answer: "Removals go to the Trash by default and can be put back. Permanent deletion is a separate, opt-in checkbox. Only Tier 3, the destructive one, asks for more than that: selecting a Tier 3 item makes you type DELETE first, whether you are trashing it or not. Anything costly to regenerate stays locked until you unlock it."),
        Entry(tag: "SAFETY",
              question: "Does it guess which files belong to an app?",
              answer: "A path is attributed when something declares the relationship: a container, an entitlement, a Homebrew stanza, or an installer receipt. Matching folder names to app names is not used."),
        Entry(tag: "PERMISSIONS",
              question: "Do I have to give it Full Disk Access?",
              answer: "No. It works without, and tells you which totals are undercounts as a result. That is your call to make with the numbers in front of you."),
        Entry(tag: "PERMISSIONS",
              question: "Why did macOS ask for my password?",
              answer: "You removed an app installed for everyone on the Mac. Those belong to the system, so DDCC asks Finder to move it and macOS authenticates you. The app itself never holds elevated privileges."),
        Entry(tag: "SCOPE",
              question: "Will it find everything?",
              answer: "No, and it says so. Caches finds known patterns. Files finds large, long-unmodified items outside those. A folder of ten thousand small files can hide from both."),
        Entry(tag: "SCOPE",
              question: "Does it work on Intel Macs?",
              answer: "Yes. Apple silicon and Intel, macOS 15 or later."),
        Entry(tag: "LICENCE",
              question: "Can I use it at work?",
              answer: "Yes, royalty-free, permanently. The licence covers personal use and a company's own internal use. Only redistributing it commercially needs a separate arrangement."),
        Entry(tag: "LICENCE",
              question: "Is DDCC open source?",
              answer: "No. DDCC is source-available under the Sustainable Use License, which is not OSI-approved. You can read every line and use it personally or inside your own company at no cost; redistributing it commercially needs a separate arrangement. If OSI-approved open source is what you need, DDCC does not qualify."),
        Entry(tag: "ORIGIN",
              question: "Why is it called DevDriveCacheClean?",
              answer: "It began as a tool for my own Mac: clear developer caches in one click, without first reading a blog post about which folders are safe to delete. The name is the job \u{2014} developer caches, drive space, cleaned. Deciding to release it publicly is what grew it into app footprints and large files as well."),
        Entry(tag: "TRUST",
              question: "Why should I believe any of this?",
              answer: "You shouldn't have to. The source is readable, the network claim is one grep, and every total the app shows can be checked against your own free space."),
    ]

    /// The visible cards, in the page's own `.claim` shape.
    public static var cardsHTML: String {
        entries.map { entry in
            "      <div class=\"claim\">"
            + "<span class=\"tag\">\(escapeHTML(entry.tag))</span>"
            + "<h3>\(escapeHTML(entry.question))</h3>"
            + "<p>\(escapeHTML(entry.answer))</p>"
            + "</div>"
        }.joined(separator: "\n")
    }

    /// The FAQPage block. `sortedKeys` keeps bytes stable between runs for the drift
    /// check.
    public static func structuredData() throws -> String {
        let payload: [String: Any] = [
            "@context": "https://schema.org",
            "@type": "FAQPage",
            "mainEntity": entries.map { entry in
                [
                    "@type": "Question",
                    "name": entry.question,
                    "acceptedAnswer": ["@type": "Answer", "text": entry.answer],
                ] as [String: Any]
            },
        ]
        return try StructuredData.json(payload)
    }
}
