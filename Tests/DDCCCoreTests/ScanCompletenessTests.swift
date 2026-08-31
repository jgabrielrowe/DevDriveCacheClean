import Testing
@testable import DDCCCore

@Test func anExactRunHasNoCaveat() {
    #expect(ScanCompleteness.exact.isExact)
    #expect(ScanCompleteness.exact.caveat == nil)
}

/// Each counter alone must be enough to make a total inexact. Written as three
/// separate constructions rather than one combined value because a single
/// `&&`/`||` slip in `isExact` would still pass a test that only ever sets all
/// three at once.
@Test func anyOneCounterMakesTheTotalInexact() {
    #expect(!ScanCompleteness(unreadableDirectories: 1, flooredItems: 0, unmeasuredItems: 0).isExact)
    #expect(!ScanCompleteness(unreadableDirectories: 0, flooredItems: 1, unmeasuredItems: 0).isExact)
    #expect(!ScanCompleteness(unreadableDirectories: 0, flooredItems: 0, unmeasuredItems: 1).isExact)
}

@Test func theCaveatNamesEveryReasonTheTotalIsNotExact() {
    let all = ScanCompleteness(unreadableDirectories: 3, flooredItems: 2, unmeasuredItems: 41)
    let caveat = try! #require(all.caveat)
    #expect(caveat.contains("3 folders could not be read"))
    #expect(caveat.contains("2 sizes partial"))
    #expect(caveat.contains("41 items not measured"))
}

/// A caveat naming a reason that did not happen is as misleading as one that
/// omits a reason that did.
@Test func theCaveatOmitsReasonsThatDidNotHappen() {
    let onlyUnreadable = ScanCompleteness(
        unreadableDirectories: 1, flooredItems: 0, unmeasuredItems: 0)
    let caveat = try! #require(onlyUnreadable.caveat)
    #expect(caveat == "1 folder could not be read")
}

@Test func theCaveatIsSingularForOne() {
    #expect(ScanCompleteness(unreadableDirectories: 1, flooredItems: 0, unmeasuredItems: 0)
        .caveat == "1 folder could not be read")
    #expect(ScanCompleteness(unreadableDirectories: 0, flooredItems: 1, unmeasuredItems: 0)
        .caveat == "1 size partial")
    #expect(ScanCompleteness(unreadableDirectories: 0, flooredItems: 0, unmeasuredItems: 1)
        .caveat == "1 item not measured")
}
