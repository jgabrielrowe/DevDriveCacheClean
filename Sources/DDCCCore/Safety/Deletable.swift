// Sources/DDCCCore/Safety/Deletable.swift
import Foundation

/// The subset of a row that guarded removal actually needs.
///
/// `DeletionService`'s loop reads only these four values — never `tier` or
/// `category`. Naming that subset lets the file finder reuse the one guarded
/// removal path instead of either duplicating it or inventing a tier for rows
/// no pattern vouches for. A second implementation of guarded removal is the
/// specific thing this project's design exists to prevent.
public protocol Deletable: Sendable {
    var path: URL { get }
    var sizeBytes: Int64 { get }
    var removability: Removability { get }
    /// False for rows the app must display but can never remove.
    var isDeletable: Bool { get }
    var displayName: String { get }

    /// True for a row the guard refuses on root ownership alone, which
    /// `DeletionService` may remove through an authenticated route instead of
    /// failing. Defaulted to `false`: only an app's own `.app` bundle ever
    /// sets it, and every other conformer keeps failing closed.
    var requiresAuthentication: Bool { get }
}

extension Deletable {
    public var requiresAuthentication: Bool { false }
}

extension ScanResult: Deletable {}
