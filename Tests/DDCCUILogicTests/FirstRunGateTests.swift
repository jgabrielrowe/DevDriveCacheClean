import Testing
import Foundation
@testable import DDCCUI

/// Each test gets its own defaults suite. Against `.standard` the first run
/// would pass and every run after it would pass for the wrong reason — the
/// key would already be set, by a previous test or by the developer's own
/// copy of the app.
private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func aFreshInstallHasNotAcceptedAnything() {
    #expect(FirstRunGate(defaults: freshDefaults()).needsAcceptance)
}

@Test func acceptingIsRememberedAcrossLaunches() {
    let defaults = freshDefaults()
    FirstRunGate(defaults: defaults).accept()
    // A second gate over the same storage is what the next launch sees.
    #expect(FirstRunGate(defaults: defaults).needsAcceptance == false)
}

/// The point of storing a version rather than a flag. Someone who accepted
/// version 1 has not accepted a later version, and the gate has to be able to
/// tell the difference — otherwise raising the version would do nothing and
/// the field might as well be a `Bool`.
@Test func acceptingAnEarlierVersionDoesNotCoverALaterOne() {
    let defaults = freshDefaults()
    defaults.set(FirstRunGate.currentTermsVersion - 1, forKey: "acceptedTermsVersion")
    #expect(FirstRunGate(defaults: defaults).needsAcceptance)
}

@Test func acceptingRecordsTheVersionAndNotMerelyThatItHappened() throws {
    let defaults = freshDefaults()
    FirstRunGate(defaults: defaults).accept()
    #expect(defaults.integer(forKey: "acceptedTermsVersion") == FirstRunGate.currentTermsVersion)

    // The assertion above cannot tell `1` from `true`: UserDefaults reads a
    // stored boolean back as the integer 1, and the current version is 1. So
    // it passes for a gate that writes a flag — until the day the version is
    // raised, when accept() would store 1 against a required 2 and the sheet
    // would reappear on every launch, for ever, with no way for the user to
    // get past it. Found by mutation: replacing the stored value with `true`
    // failed nothing.
    let stored = try #require(defaults.object(forKey: "acceptedTermsVersion"))
    #expect(
        CFGetTypeID(stored as CFTypeRef) != CFBooleanGetTypeID(),
        "acceptance is stored as a boolean, not as a version number")
}

/// A version from the future — someone downgrading the app — must not be
/// walked backwards into being asked again, and must not be overwritten with
/// a lower number by an older build that happens to run once.
@Test func aLaterAcceptedVersionStillCounts() {
    let defaults = freshDefaults()
    defaults.set(FirstRunGate.currentTermsVersion + 1, forKey: "acceptedTermsVersion")
    #expect(FirstRunGate(defaults: defaults).needsAcceptance == false)
}
