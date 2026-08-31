import Foundation

/// Whether the user has accepted the terms, and at which version.
///
/// The licence already says "by using the software, you agree" — this exists
/// to turn that into a record. An affirmative click is evidence in a way that
/// a clause nobody was shown is not, which is the whole reason to interrupt
/// someone before they have used the app once.
///
/// A version rather than a flag: if the terms change materially, raising
/// `currentTermsVersion` asks again, and someone who accepted version 1 is not
/// silently treated as having accepted version 2. A `Bool` would have made
/// that impossible without a migration.
struct FirstRunGate {

    /// Raise this only when the terms change in a way a reasonable person
    /// would want to see again. Cosmetic edits do not count; nagging people
    /// who already agreed teaches them to click through without reading.
    static let currentTermsVersion = 1

    private static let key = "acceptedTermsVersion"
    private let defaults: UserDefaults

    /// Injectable so a test can use its own suite: the tests would otherwise
    /// write to the real user's preferences and pass on the second run for
    /// the wrong reason.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `integer(forKey:)` is 0 for a key that has never been set, so a fresh
    /// install falls through to needing acceptance without a separate check.
    var needsAcceptance: Bool {
        defaults.integer(forKey: Self.key) < Self.currentTermsVersion
    }

    /// The version accepted, not `true`, so a later version can tell the
    /// difference between "agreed to these terms" and "agreed to some terms".
    func accept() {
        defaults.set(Self.currentTermsVersion, forKey: Self.key)
    }
}
