// Sources/DDCCCore/Uninstall/EntitlementReader.swift
import Foundation
import Security

/// Reads an app bundle's `com.apple.security.application-groups` entitlement.
///
/// A `~/Library/Group Containers/<team>.<id>` directory is shared by every app
/// granted that entitlement — measured: Affinity Designer 2, Photo 2 and
/// Publisher 2 all declare `6LVTQB9699.com.seriflabs` and share one 1.76 GB
/// container. The entitlement is the OS's own access grant, authoritative in a
/// way a directory name is not.
///
/// Uses Security.framework rather than `codesign -d --entitlements` because
/// shipping code in this project spawns no subprocesses, which `README.md`
/// publishes as a guarantee. The signature data is the same.
///
/// Answers rather than throws: an unsigned, corrupt, or unopenable bundle is an
/// expected input on a walk of arbitrary bundles, and throwing would turn one
/// of them into an aborted scan.
public enum EntitlementReader {

    /// The application groups `bundleURL` declares, empty if its signature was
    /// read and names none, or `nil` if the signature could not be read.
    ///
    /// The two are different facts and only one is a finding. Read-and-none
    /// makes the app a claimant of nothing, which is true. Could-not-read says
    /// nothing about what the app claims, and reporting it as "claims nothing"
    /// removes a rival's claim on a shared container — releasing it while that
    /// rival is still using it. Measured: an unsigned directory and an absent
    /// path both fail `SecStaticCodeCreateWithPath`.
    ///
    /// A groups key present but not an array of strings also answers `nil`:
    /// something was declared and this cannot say what.
    public static func applicationGroups(of bundleURL: URL) -> Set<String>? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return nil }

        var signingInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSRequirementInformation), &signingInformation)
        guard infoStatus == errSecSuccess,
              let signingInformation = signingInformation as? [String: Any]
        else { return nil }

        guard let entitlements = signingInformation[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }

        guard let declared = entitlements["com.apple.security.application-groups"] else { return [] }
        guard let groups = declared as? [String] else { return nil }

        return Set(groups)
    }
}
