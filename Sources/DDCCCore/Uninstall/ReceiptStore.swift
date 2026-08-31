// Sources/DDCCCore/Uninstall/ReceiptStore.swift
import Foundation

/// One macOS installer receipt: the identity, install location, and file
/// manifest of a package the system's `installer`/`pkgutil` machinery
/// recorded under `/var/db/receipts`.
///
/// A receipt is one of the design's few genuinely *authoritative* sources
/// for an application's footprint — the installer itself wrote it, so it is
/// a record rather than an inference. `ReceiptStore` only reads and joins;
/// what to do with a joined path — attribute it, allow it, refuse it — is
/// decided by `FootprintAssembler`.
public struct Receipt: Sendable, Equatable {
    /// `PackageIdentifier` from the plist, e.g. `com.apple.pkg.Xcode`.
    public let packageID: String

    /// `InstallPrefixPath` verbatim from the plist. Measured across the 78
    /// receipts on the development machine, this is always one of: absent
    /// (treated as `""`), `""`, the literal `"/"`, or a path with **no**
    /// leading slash (`"Applications"`, `"usr/local/share/dotnet"`).
    /// `paths(of:)` is what turns this into an absolute prefix; nothing
    /// here assumes the shape ahead of that.
    public let installPrefix: String

    /// The sibling `.bom` file's URL — same directory, same basename as the
    /// plist — set only when that file exists on disk at construction time.
    /// `nil` means "no manifest to read for this package," which is a
    /// normal state (some receipts are metadata-only), not an error.
    public let bomURL: URL?

    public init(packageID: String, installPrefix: String, bomURL: URL?) {
        self.packageID = packageID
        self.installPrefix = installPrefix
        self.bomURL = bomURL
    }
}

/// Reads installer receipts from a directory (in practice
/// `/var/db/receipts`) and joins each one's `BOMReader` manifest to its
/// install prefix.
///
/// **A caller that matches these joined paths against anything else must
/// match exactly, never by prefix.** `BOMReader` documents that a
/// non-UTF-8 filename in a BOM decodes lossily: the string that comes back
/// is not guaranteed byte-identical to what is on disk. A prefix/subtree
/// match built on a lossily-decoded path could silently claim files that
/// were never part of this package. Exact string equality turns that
/// failure into a miss (the path is skipped) rather than a misattribution
/// (a wrong directory gets treated as this package's) — a missed path only
/// under-reports a footprint, a mis-matched one can delete someone else's
/// data. This type performs no matching itself — the attribution policy is
/// `FootprintAssembler`'s — but its output is shaped for exact comparison:
/// see `joinedPathKey(bomPath:prefix:)`.
public enum ReceiptStore {

    /// Whether `dir` could be listed at all — the distinction
    /// `receipts(in:)` deliberately collapses, since an empty result serves
    /// a caller that only wants receipts. A caller deciding whether a
    /// receipt's *absence* proves anything needs the two apart: nothing
    /// found in a readable directory is evidence, nothing found in a
    /// directory that could not be opened is not.
    ///
    /// Named for the act, not for a property of the directory, so it cannot
    /// be read as `Claim.isEnumerable` — an unrelated flag meaning that a
    /// claim *mechanism* is closed rather than that a listing succeeded.
    public static func canEnumerate(_ dir: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [])) != nil
    }

    /// Every receipt in `dir`, one per `.plist` file found there.
    ///
    /// A directory that cannot be listed — absent, unreadable, not a
    /// directory, permissions denied — yields an empty array rather than
    /// throwing: a machine with no receipts, or a sandbox without access to
    /// `/var/db/receipts`, is a normal state, and this source simply
    /// contributes nothing to the result.
    public static func receipts(in dir: URL) -> [Receipt] {
        read(in: dir).receipts
    }

    /// Every receipt in `dir`, and whether every plist there yielded one.
    ///
    /// `receipts(in:)` is this without the flag, which is all a caller
    /// *looking for* a receipt needs: one bad plist costs that receipt and no
    /// other. A caller reading a **miss** as proof needs the flag, because
    /// dropping a receipt silently is indistinguishable from that receipt
    /// never having existed — and `CaskPresence` proves a `pkgutil`-only cask
    /// absent from exactly such a miss, which stops its paths refusing.
    ///
    /// `canEnumerate` draws the same line one level up, between a directory
    /// that would not open and one that opened empty. This draws it inside a
    /// directory that opened: `fullyRead` is false when the listing failed, and
    /// false when any `.plist` in it could not be turned into a receipt.
    ///
    /// An empty database that listed reads **complete**, not short. Nothing was
    /// there to miss, and that emptiness is itself the finding that legitimately
    /// proves a `pkgutil`-only cask absent — marking it short would disable that
    /// proof on every machine that has no receipts.
    public static func read(in dir: URL) -> (receipts: [Receipt], fullyRead: Bool) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [])
        else { return ([], false) }

        let plists = entries.filter { $0.pathExtension == "plist" }
        let receipts = plists.compactMap(receipt(fromPlistAt:))
        return (receipts, receipts.count == plists.count)
    }

    /// Reads one receipt's identity and prefix from its plist, or `nil` if
    /// the plist is missing, unreadable, malformed, or lacks
    /// `PackageIdentifier`. A receipt this process cannot name is not one
    /// it can attribute anything to — skipping it here means one bad plist
    /// costs that receipt, never the whole scan.
    private static func receipt(fromPlistAt plistURL: URL) -> Receipt? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any],
              let packageID = plist["PackageIdentifier"] as? String,
              !packageID.isEmpty
        else { return nil }

        let installPrefix = (plist["InstallPrefixPath"] as? String) ?? ""

        let bomName = plistURL.deletingPathExtension().lastPathComponent + ".bom"
        let bomCandidate = plistURL
            .deletingLastPathComponent()
            .appending(path: bomName, directoryHint: .notDirectory)
        let bomURL = FileManager.default.fileExists(
            atPath: bomCandidate.path(percentEncoded: false)) ? bomCandidate : nil

        return Receipt(packageID: packageID, installPrefix: installPrefix, bomURL: bomURL)
    }

    /// Every path this receipt's package installed, each an absolute,
    /// normalized string `FootprintAssembler` compares against its
    /// allowlist.
    /// `Candidate.normalizedPathKey(for:)` — this project's one path-key
    /// derivation — does that normalization; it is reused rather than
    /// re-implemented here, per the rule recorded on that function (the
    /// same normalization bug recurred independently in three files before
    /// that rule existed).
    ///
    /// `nil` when there is no `.bom` to read, or when `BOMReader` refuses
    /// the one there is — both mean "this receipt told us nothing." Per
    /// `BOMReader`'s own contract, `nil` never means "installed nothing,"
    /// and this passes that guarantee through rather than collapsing it to
    /// an empty array.
    public static func paths(of receipt: Receipt) -> [String]? {
        guard let bomURL = receipt.bomURL,
              let bomPaths = BOMReader.paths(at: bomURL)
        else { return nil }

        let prefix = installPrefixURL(receipt.installPrefix)
        return bomPaths.map { joinedPathKey(bomPath: $0, prefix: prefix) }
    }

    /// Resolves `InstallPrefixPath` to the absolute directory BOM entries
    /// are relative to.
    ///
    /// Absent (`""`) and the literal `"/"` both mean "the volume root" —
    /// three receipts on the development machine (Apple's own
    /// `Xcode.pkg`, `GarageBand_AppStore.pkg`, `iMovie_AppStore.pkg`) use
    /// the `"/"` spelling; everything else that installs at the root
    /// simply leaves the key out. Anything else measured is a path
    /// *without* a leading slash (`"Applications"`), so one is added here;
    /// a value that already has one is accepted as-is rather than doubled,
    /// in case a receipt this project has not seen spells it that way.
    private static func installPrefixURL(_ prefix: String) -> URL {
        if prefix.isEmpty || prefix == "/" {
            return URL(fileURLWithPath: "/", isDirectory: true)
        }
        let absolute = prefix.hasPrefix("/") ? prefix : "/" + prefix
        return URL(fileURLWithPath: absolute, isDirectory: true)
    }

    /// Joins one BOM entry to the resolved install prefix and normalizes
    /// the result.
    ///
    /// A BOM's root entry is the literal string `"."`, standing for the
    /// install prefix directory *itself* — it is not a path component to
    /// append, so it maps straight to the prefix. Every other entry starts
    /// with `"./"`, which is stripped before joining; without that,
    /// joining the root prefix `"/"` to `"./foo"` would produce `"//foo"`
    /// instead of `"/foo"`.
    private static func joinedPathKey(bomPath: String, prefix: URL) -> String {
        guard bomPath != "." else {
            return Candidate.normalizedPathKey(for: prefix)
        }
        let relative = bomPath.hasPrefix("./") ? String(bomPath.dropFirst(2)) : bomPath
        let joined = prefix.appending(path: relative, directoryHint: .notDirectory)
        return Candidate.normalizedPathKey(for: joined)
    }
}
