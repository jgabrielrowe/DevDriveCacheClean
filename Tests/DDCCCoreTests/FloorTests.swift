import Foundation
import Testing

@testable import DDCCCore

/// The marker is a promise that a figure is a lower bound, so the direction
/// matters more than the character: appended when the reading fell short, and
/// absent when it did not.
@Suite struct FloorTests {

    @Test func anExactFigureCarriesNoMarker() {
        #expect(Floor.marked("1.2 GB", exact: true) == "1.2 GB")
    }

    @Test func aShortReadingIsMarkedAsAFloor() {
        #expect(Floor.marked("1.2 GB", exact: false) == "1.2 GB+")
    }

    /// The completeness overload exists so a caller holding the type cannot
    /// invert the polarity, which is the mistake the scattered ternaries
    /// invited — two of them asked `partialRead` and two asked `isExact`.
    @Test func theCompletenessOverloadAgreesWithTheBooleanOne() {
        let short = ScanCompleteness(
            unreadableDirectories: 1, flooredItems: 0, unmeasuredItems: 0)
        #expect(short.isExact == false)
        #expect(Floor.marked("40 rows listed", short) == "40 rows listed+")
        #expect(Floor.marked("40 rows listed", .exact) == "40 rows listed")
    }
}
