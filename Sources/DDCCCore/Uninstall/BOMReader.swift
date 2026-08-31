// Sources/DDCCCore/Uninstall/BOMReader.swift
import Foundation

/// Reads the path manifest out of a macOS installer receipt (`/var/db/receipts/*.bom`).
///
/// Receipts are authoritative: the installer wrote the list, so it is a record
/// rather than an inference.
///
/// The format is reverse-engineered, not documented by Apple. Every offset is a
/// `UInt32` from a file this process did not write, and this process holds Full
/// Disk Access and deletes files, so:
///
/// - every block address and length is bounds-checked against the file before
///   any slice is taken;
/// - any structural surprise — absent magic, missing `Paths` var, a block too
///   short for the record it should hold, a path count that disagrees with the
///   tree header — returns `nil` for the whole file. A partial manifest is
///   worse than no manifest, because a caller cannot tell it is partial;
/// - the parent-id chain that rebuilds a full path carries an explicit visited
///   set. A corrupt receipt can make that chain cyclic, and recursion depth is
///   not a safety mechanism;
/// - no force-unwraps and no `try!`.
///
/// Verified against the system's own reference reader for the format, over
/// every receipt on a real machine — see `BOMReaderTests`, which runs it. That
/// reader is a subprocess, so it belongs in a test: shipping code spawns
/// nothing here.
///
/// `bomutils`, the widely referenced open-source implementation, is GPLv3 and
/// was not copied from; this parser is written from a measured description of
/// the layout.
public enum BOMReader {

    /// Receipts are manifests, not payloads. The largest on the development
    /// machine was Xcode's at 38 MB with 158,717 paths, so 256 MB is far above
    /// anything legitimate. A file larger than this is refused outright rather
    /// than read or mapped, because the cost of finding out what it is would be
    /// paid before the first bounds check.
    private static let maxFileBytes = 256 * 1024 * 1024

    /// A `BOMFile` record holds one path *component*, and `NAME_MAX` on every
    /// filesystem macOS mounts is 255 bytes, so a longer one is not a name this
    /// process could ever act on. Measured: the longest of the
    /// 426,953 names in the 78 receipts on the development machine is 100 bytes.
    private static let maxNameBytes = 255

    /// Block index 0 is the null block: the block table's entry 0 is literally
    /// `(address: 0, length: 0)`, and the format uses index 0 as its "nothing
    /// here" sentinel — most visibly as the `forward` pointer of the last leaf.
    ///
    /// Left unguarded, index 0 resolves to an empty slice, the record read out
    /// of it comes up short, and the whole parse fails.
    ///
    /// The load-bearing guard is the leaf-chain walk, which stops when
    /// `forward` is this. `blockRange(_:)` also refuses it — defence in depth,
    /// since a zero-length region is refused anyway — to keep the intent
    /// readable where an index becomes a slice.
    private static let nullBlock: UInt32 = 0

    /// Returns every path recorded in the receipt at `url`, in the order the
    /// manifest lists them, or `nil` if the file is not a readable BOM.
    ///
    /// `nil` means "this told us nothing", never "this app installed nothing" —
    /// a caller that reports a footprint must not treat the two as equal.
    public static func paths(at url: URL) -> [String]? {
        guard let bytes = readCapped(url) else { return nil }
        return Parser(bytes: bytes)?.paths()
    }

    /// Reads at most the cap, and refuses a file that turns out to be longer.
    ///
    /// Deliberately not "stat, then `Data(contentsOf:)`": that enforces the cap
    /// *after* the whole file has already been allocated, and a file that grows
    /// between the two calls is read at whatever size it reached. Asking for
    /// `maxFileBytes + 1` bytes makes the limit a property of the read itself —
    /// a longer file is detected by the extra byte coming back and never gets
    /// further than that.
    private static func readCapped(_ url: URL) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1),
              data.count <= maxFileBytes
        else { return nil }
        return [UInt8](data)
    }

    /// One record from a leaf: a file's own name and the id of its parent.
    private struct Entry {
        let parent: UInt32
        let name: String
    }

    /// Holds the whole file and the decoded block table. Every accessor is
    /// bounds-checked; there is no unchecked path to the bytes.
    private struct Parser {
        private let bytes: [UInt8]
        /// Block table, indexed by block number. Entry 0 is the null block.
        private let blocks: [(address: UInt32, length: UInt32)]
        /// Block index of the `Paths` variable's tree block.
        private let pathsBlock: UInt32

        // MARK: - Header

        init?(bytes: [UInt8]) {
            self.bytes = bytes
            // Magic (8) + six UInt32 fields.
            guard bytes.count >= 32,
                  bytes[0..<8].elementsEqual(Array("BOMStore".utf8))
            else { return nil }
            let header = Reader(bytes: bytes)
            guard let indexOffset = header.u32(16),
                  let indexLength = header.u32(20),
                  let varsOffset = header.u32(24),
                  let varsLength = header.u32(28),
                  let blocks = Parser.readBlockTable(
                      bytes, offset: indexOffset, length: indexLength),
                  let pathsBlock = Parser.readPathsVar(
                      bytes, offset: varsOffset, length: varsLength)
            else { return nil }
            self.blocks = blocks
            self.pathsBlock = pathsBlock
        }

        /// Block table: a `UInt32` count followed by that many `(address,
        /// length)` pairs. The count is trusted only after it is shown to fit
        /// inside the table's own declared length *and* inside the file, so a
        /// hostile count cannot drive a huge allocation.
        private static func readBlockTable(
            _ bytes: [UInt8], offset: UInt32, length: UInt32
        ) -> [(address: UInt32, length: UInt32)]? {
            let reader = Reader(bytes: bytes)
            guard let region = reader.region(address: offset, length: length),
                  let count = reader.u32(region.lowerBound),
                  let needed = span(count: count, stride: 8, header: 4),
                  needed <= region.count
            else { return nil }
            var table: [(address: UInt32, length: UInt32)] = []
            table.reserveCapacity(Int(count))
            var cursor = region.lowerBound + 4
            for _ in 0..<count {
                guard let address = reader.u32(cursor),
                      let blockLength = reader.u32(cursor + 4)
                else { return nil }
                table.append((address, blockLength))
                cursor += 8
            }
            return table
        }

        /// Vars: a `UInt32` count, then per variable a `UInt32` block index, a
        /// `UInt8` name length, and that many name bytes. The one named `Paths`
        /// holds the tree; a receipt without it is not something to guess at.
        private static func readPathsVar(
            _ bytes: [UInt8], offset: UInt32, length: UInt32
        ) -> UInt32? {
            let reader = Reader(bytes: bytes)
            guard let region = reader.region(address: offset, length: length),
                  let count = reader.u32(region.lowerBound)
            else { return nil }
            var cursor = region.lowerBound + 4
            for _ in 0..<count {
                guard let index = reader.u32(cursor),
                      let nameLength = reader.u8(cursor + 4)
                else { return nil }
                let nameStart = cursor + 5
                let nameEnd = nameStart + Int(nameLength)
                guard nameEnd <= region.upperBound else { return nil }
                if bytes[nameStart..<nameEnd].elementsEqual(Array("Paths".utf8)) {
                    return index
                }
                cursor = nameEnd
            }
            return nil
        }

        // MARK: - Tree walk

        /// A path block's fixed header: `UInt16` isLeaf, `UInt16` count,
        /// `UInt32` forward, `UInt32` backward. Twelve bytes, not sixteen —
        /// the two `UInt16`s pack together rather than being padded out.
        private static let pathHeader = 12

        /// Rebuilds every full path in the manifest, or `nil` on any structural
        /// surprise.
        func paths() -> [String]? {
            // Tree block: "tree" magic, version, child block index, blockSize,
            // pathCount.
            let reader = Reader(bytes: bytes)
            guard let tree = blockRange(pathsBlock), tree.count >= 20,
                  bytes[tree.lowerBound..<(tree.lowerBound + 4)]
                      .elementsEqual(Array("tree".utf8)),
                  let child = reader.u32(tree.lowerBound + 8),
                  let pathCount = reader.u32(tree.lowerBound + 16),
                  let leaf = descendToFirstLeaf(from: child)
            else { return nil }

            // `pathCount` is a header field from an untrusted file, so it sizes
            // nothing on its own: reserving `UInt32.max` entries would exhaust
            // memory before a single bounds check had run. Every path costs at
            // least its 8-byte index pair in a leaf, so the file's own size is
            // the real ceiling. This only clamps a hint — the count is verified
            // exactly after the walk.
            let plausible = min(Int(pathCount), bytes.count / 8)
            var entries: [UInt32: Entry] = [:]
            entries.reserveCapacity(plausible)
            var order: [UInt32] = []
            order.reserveCapacity(plausible)
            guard collectLeaves(from: leaf, limit: plausible, into: &entries, order: &order)
            else { return nil }

            // The tree header states how many paths it holds. A disagreement
            // means the walk did not see the manifest the file describes, and
            // "most of a manifest" is exactly the answer this must not give.
            guard order.count == Int(pathCount) else { return nil }

            var cache: [UInt32: String] = [:]
            cache.reserveCapacity(order.count)
            var result: [String] = []
            result.reserveCapacity(order.count)
            for id in order {
                guard let path = fullPath(of: id, entries: entries, cache: &cache)
                else { return nil }
                result.append(path)
            }
            return result
        }

        /// Walks down the interior nodes to the leftmost leaf. Interior nodes
        /// hold the child block index in the first element of each pair.
        ///
        /// The visited set is not optional: a corrupt file can point a node at
        /// itself or at an ancestor, and a bounded descent would only turn an
        /// infinite loop into a wrong answer.
        private func descendToFirstLeaf(from start: UInt32) -> Range<Int>? {
            let reader = Reader(bytes: bytes)
            var visited: Set<UInt32> = []
            var index = start
            while true {
                guard visited.insert(index).inserted,
                      let block = blockRange(index), block.count >= Parser.pathHeader,
                      let isLeaf = reader.u16(block.lowerBound),
                      let count = reader.u16(block.lowerBound + 2)
                else { return nil }
                if isLeaf != 0 { return block }
                // An interior node with no children has nowhere to descend to,
                // and guessing is not an option.
                guard count >= 1,
                      block.count >= Parser.pathHeader + 8,
                      let firstChild = reader.u32(block.lowerBound + Parser.pathHeader)
                else { return nil }
                index = firstChild
            }
        }

        /// Reads every leaf, following the `forward` chain from the first one.
        ///
        /// Each leaf pair is `(BOMPathInfo1, BOMFile)` **in that order**, and
        /// the order is dangerous to get wrong: under looser reading every name
        /// comes out empty while the path count stays exactly right, so the
        /// parse looks successful and is silently wrong. Swapping them here is
        /// caught only because a `BOMFile` block does not survive being read as
        /// a `BOMPathInfo1` — luck earned by the length checks. The differential
        /// in `BOMReaderTests` is what actually knows.
        /// `limit` bounds what may accumulate *while* the walk runs. The exact
        /// completeness check in `paths()` rejects the same files, but only
        /// once everything has been built — so on its own it is a correctness
        /// check with no bound on the memory spent reaching it. This one is the
        /// bound; it stops on the first entry past what the file could hold.
        private func collectLeaves(
            from first: Range<Int>,
            limit: Int,
            into entries: inout [UInt32: Entry],
            order: inout [UInt32]
        ) -> Bool {
            let reader = Reader(bytes: bytes)
            var visited: Set<UInt32> = []
            var block: Range<Int>? = first
            while let leaf = block {
                guard let count = reader.u16(leaf.lowerBound + 2),
                      let forward = reader.u32(leaf.lowerBound + 4),
                      let needed = Parser.span(
                          count: UInt32(count), stride: 8, header: Parser.pathHeader),
                      needed <= leaf.count
                else { return false }
                var cursor = leaf.lowerBound + Parser.pathHeader
                for _ in 0..<count {
                    guard let infoIndex = reader.u32(cursor),
                          let fileIndex = reader.u32(cursor + 4),
                          let id = pathID(infoIndex),
                          let entry = fileEntry(fileIndex)
                    else { return false }
                    // Two leaf records claiming the same id would make the
                    // parent chain ambiguous.
                    guard entries.updateValue(entry, forKey: id) == nil else { return false }
                    order.append(id)
                    guard order.count <= limit else { return false }
                    cursor += 8
                }
                // The last leaf's `forward` is the null block. Stopping here is
                // the null-block guard: without it the walk resolves index 0,
                // gets an empty slice, and the whole parse fails. Verified by
                // deleting this line — the differential goes red on the first
                // receipt it reads.
                guard forward != BOMReader.nullBlock else { break }
                guard visited.insert(forward).inserted,
                      let next = blockRange(forward), next.count >= Parser.pathHeader
                else { return false }
                block = next
            }
            return true
        }

        /// `BOMPathInfo1`: a `UInt32` id and a `UInt32` index into a
        /// `BOMPathInfo2` block. Only the id matters here — the mode, uid, gid
        /// and size in `BOMPathInfo2` are not part of a path manifest.
        private func pathID(_ index: UInt32) -> UInt32? {
            guard let block = blockRange(index), block.count >= 8 else { return nil }
            return Reader(bytes: bytes).u32(block.lowerBound)
        }

        /// `BOMFile`: a `UInt32` parent id followed by a NUL-terminated name.
        ///
        /// The name is taken verbatim, byte for byte up to the NUL. Receipts
        /// contain names that look like noise but are not — AppleDouble
        /// sidecars such as `._Icon\r` among them — and trimming or
        /// "cleaning" any of it produces a path that does not exist on disk.
        ///
        /// A name that is not valid UTF-8 decodes with replacement characters
        /// rather than failing the whole receipt over one entry — none of the
        /// 426,953 names across 78 receipts on one machine needed it. Such a
        /// path must still be matched exactly, never by prefix, since a replaced
        /// name no longer identifies the file it came from.
        private func fileEntry(_ index: UInt32) -> Entry? {
            guard let block = blockRange(index), block.count >= 5,
                  let parent = Reader(bytes: bytes).u32(block.lowerBound)
            else { return nil }
            let nameStart = block.lowerBound + 4
            // Search only as far as a name is allowed to be. Without this the
            // name is bounded by the *block*, so one entry could be as long as
            // the whole file — and nothing requires the leaf pairs to point at
            // distinct `BOMFile` blocks, so every entry in the manifest may
            // point at that same oversized one and each allocates its own copy.
            // A crafted 1 MB file drove roughly 14 GB that way. A `BOMFile`
            // name is a single path component, so `NAME_MAX` is the format's
            // own ceiling and anything past it is not a name.
            let limit = min(nameStart + BOMReader.maxNameBytes + 1, block.upperBound)
            guard let nul = bytes[nameStart..<limit].firstIndex(of: 0)
            else { return nil }
            return Entry(
                parent: parent,
                name: String(decoding: bytes[nameStart..<nul], as: UTF8.self))
        }

        // MARK: - Path reconstruction

        /// Rebuilds one full path by walking parent ids upward until parent `0`
        /// terminates the chain, memoising each ancestor on the way back down.
        ///
        /// The walk is iterative and carries a visited set. A receipt whose
        /// parent ids form a cycle is a file this process can be handed, and
        /// neither a recursion limit nor stack depth is an answer to it.
        private func fullPath(
            of id: UInt32, entries: [UInt32: Entry], cache: inout [UInt32: String]
        ) -> String? {
            if let known = cache[id] { return known }
            var chain: [UInt32] = []
            var visited: Set<UInt32> = []
            var current = id
            var prefix = ""
            while current != 0 {
                guard visited.insert(current).inserted else { return nil }
                if let known = cache[current] {
                    prefix = known
                    break
                }
                guard let entry = entries[current] else { return nil }
                chain.append(current)
                current = entry.parent
            }
            var path = prefix
            for step in chain.reversed() {
                guard let entry = entries[step] else { return nil }
                path = path.isEmpty ? entry.name : path + "/" + entry.name
                cache[step] = path
            }
            return path.isEmpty ? nil : path
        }

        // MARK: - Bounds-checked access

        /// Resolves a block index to a byte range inside the file, or `nil` if
        /// anything about it is off. Nothing in this parser slices the file
        /// except through here.
        private func blockRange(_ index: UInt32) -> Range<Int>? {
            // The null block. See `BOMReader.nullBlock`.
            // Widen the index rather than narrowing the count: `UInt32(count)`
            // would be a trapping conversion, which is not a bounds check.
            guard index != BOMReader.nullBlock, Int(index) < blocks.count else { return nil }
            let block = blocks[Int(index)]
            return Reader(bytes: bytes).region(address: block.address, length: block.length)
        }

        /// Byte span of `count` records of `stride` bytes after a `header`,
        /// or `nil` if that overflows. `Int` is 64-bit on every platform this
        /// ships to, so widening a `UInt32` never traps; the multiply is what
        /// needs the check.
        private static func span(count: UInt32, stride: Int, header: Int) -> Int? {
            let (product, overflow) = Int(count).multipliedReportingOverflow(by: stride)
            guard !overflow else { return nil }
            let (total, carry) = product.addingReportingOverflow(header)
            guard !carry else { return nil }
            return total
        }
    }

    /// Big-endian scalar reads that refuse to run off the end of the buffer.
    private struct Reader {
        let bytes: [UInt8]

        func u8(_ offset: Int) -> UInt8? {
            guard offset >= 0, offset < bytes.count else { return nil }
            return bytes[offset]
        }

        func u16(_ offset: Int) -> UInt16? {
            guard offset >= 0, offset <= bytes.count - 2 else { return nil }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }

        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }

        /// The one place an untrusted `(address, length)` pair becomes a usable
        /// range. A zero length is refused: no record in this format is empty,
        /// so an empty slice always means the index was wrong.
        func region(address: UInt32, length: UInt32) -> Range<Int>? {
            let start = Int(address)
            let count = Int(length)
            guard count > 0, start <= bytes.count, count <= bytes.count - start
            else { return nil }
            return start..<(start + count)
        }
    }
}
