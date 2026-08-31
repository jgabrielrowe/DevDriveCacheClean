import Testing
import Foundation
@testable import DDCCCore

/// The picker binds to `modifiedBeforeDays` and matches it against fixed tags
/// (30 / 180 / 365). While the threshold was stored as a `Date`, elapsed time
/// pushed the derived day count off every tag after about twelve hours of
/// uptime and the picker rendered blank.
@Test func theDayCountDoesNotDriftWithUptime() {
    let criteria = FinderCriteria(minimumBytes: 0, modifiedBeforeDays: 180)
    #expect(criteria.modifiedBeforeDays == 180)

    // Thirteen hours later — past the point the old stored-Date version broke.
    let later = Date(timeIntervalSinceNow: 60 * 60 * 13)
    let cutoff = try! #require(criteria.cutoff(from: later))
    let days = later.timeIntervalSince(cutoff) / (60 * 60 * 24)
    #expect(Int(days.rounded()) == 180)
    // And the stored value itself is untouched by the passage of time.
    #expect(criteria.modifiedBeforeDays == 180)
}

/// `init`'s `max(0, ...)` clamp is not an inert guard: `cutoff(from:)`
/// already returns nil for a negative day count, so the age filter would
/// disengage safely even without it — but without the clamp the STORED value
/// would be negative, and the Age picker's tags (0/30/180/365) would match
/// none of them, rendering blank. Both halves are asserted because either
/// alone leaves the picker-blank path unpinned.
@Test func negativeDayCountIsClampedToZero() {
    let criteria = FinderCriteria(minimumBytes: 0, modifiedBeforeDays: -5)
    #expect(criteria.modifiedBeforeDays == 0)
    #expect(criteria.cutoff(from: Date()) == nil)
}

@Test func zeroDaysMeansAnyAge() {
    let criteria = FinderCriteria(minimumBytes: 0, modifiedBeforeDays: 0)
    #expect(criteria.cutoff(from: Date()) == nil)
    #expect(criteria.matches(sizeBytes: 1, modified: Date()))
}

@Test func theDefaultsAreTheTagsThePickerOffers() {
    #expect(FinderCriteria.defaults.modifiedBeforeDays == 180)
    #expect(FinderCriteria.defaults.minimumBytes == 100_000_000)
}

/// A cutoff resolved at match time, not at construction: a criteria value built
/// at launch must still mean "180 days before now" tomorrow.
@Test func matchingResolvesTheCutoffAgainstTheMomentItIsAsked() {
    let criteria = FinderCriteria(minimumBytes: 0, modifiedBeforeDays: 30)
    let twoMonthsAgo = Date(timeIntervalSinceNow: -60 * 60 * 24 * 60)
    let yesterday = Date(timeIntervalSinceNow: -60 * 60 * 24)
    #expect(criteria.matches(sizeBytes: 1, modified: twoMonthsAgo))
    #expect(!criteria.matches(sizeBytes: 1, modified: yesterday))
}
