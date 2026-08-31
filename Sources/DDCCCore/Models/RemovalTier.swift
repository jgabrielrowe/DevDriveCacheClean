// Sources/DDCCCore/Models/RemovalTier.swift
import Foundation

/// What it costs you if this path is deleted and the classification was wrong.
public enum RemovalTier: Int, Comparable, CaseIterable, Sendable {
    /// Per-project artifact, restorable by one command from a manifest in the
    /// project. Deleting one affects one project.
    case safe = 1
    /// Global or shared state. One deletion degrades every project on the
    /// machine, or forces a large re-download with no manifest describing it.
    case costly = 2
    /// Irreplaceable, or hours of manual reconstruction. Also covers anything
    /// the scanner cannot prove is disposable.
    case destructive = 3

    public static func < (lhs: RemovalTier, rhs: RemovalTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .safe: return "Safe"
        case .costly: return "Costly"
        case .destructive: return "Destructive"
        }
    }

    public var explanation: String {
        switch self {
        case .safe:
            return "Rebuilt by one command from a file in your project."
        case .costly:
            return "Shared across every project. Comes back, but costs time and bandwidth."
        case .destructive:
            return "Cannot be recovered, or takes hours to rebuild by hand."
        }
    }
}

/// Whether the app is able to remove a path at all.
public enum Removability: Sendable, Equatable, CaseIterable {
    case removable
    /// Scanned and displayed so its size is visible, but never deletable.
    case requiresPrivileges
}

/// How a candidate was produced, used to break same-path ties.
public enum Specificity: Sendable, Equatable {
    /// From a literal `absolutePath` pattern.
    case explicit
    /// Produced by a `subdirectories` or `childSubpath` sweep.
    case enumerated
}

/// Why a scan stopped.
public enum ScanOutcome: Sendable, Equatable {
    case finished
    case cancelled
}
