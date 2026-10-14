import Darwin
import Foundation
import SFTPKit

/// F06 / S10: compare two folder trees (each on the Mac or a server), show what would change, then do it.
/// The options mirror the `synclets` table.
public struct SyncOptions: Sendable, Equatable, Codable {
    public enum Direction: String, Sendable, Codable, CaseIterable { case leftToRight = "left_to_right", rightToLeft = "right_to_left", both }
    public enum UpdateBy: String, Sendable, Codable, CaseIterable { case date, size, dateOrSize = "date_or_size", never }

    public var direction: Direction = .leftToRight
    public var subfolders = true
    public var includeHidden = false
    public var addMissing = true
    public var skipEmptyFolders = false
    public var updateBy: UpdateBy = .date
    /// Remove items from the target that aren't in the source. Off by default; never in two-way sync.
    public var deleteOrphans = false
    /// Seconds added to the right side's times (servers with a wrong clock or another time zone setting).
    public var timeOffset = 0
    /// Glob patterns matched against names and relative paths: "*.log", "node_modules", "cache/*".
    public var excludes: [String] = []
    /// Times closer than this count as equal (FAT and some servers store 2-second times).
    public var tolerance = 2

    public init() {}

    public var isValid: Bool { !(direction == .both && deleteOrphans) }
}

public struct SyncItem: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable {
        case copyToRight, copyToLeft
        case deleteRight, deleteLeft
        case createFolderRight, createFolderLeft
        case conflict(String)
        case same
    }

    public var id: String { relativePath }
    public let relativePath: String
    public let isDirectory: Bool
    public let left: FileAttributes?
    public let right: FileAttributes?
    public let action: Action
    /// "new" for an add, "newer" or "different size" for an update.
    public let reason: String
    /// Unticked items are skipped. Conflicts start unticked.
    public var included: Bool

    public var bytes: UInt64 {
        switch action {
        case .copyToRight: left?.size ?? 0
        case .copyToLeft: right?.size ?? 0
        default: 0
        }
    }

    public var isChange: Bool {
        switch action {
        case .same, .conflict: false
        default: true
        }
    }

    public var isDelete: Bool { action == .deleteLeft || action == .deleteRight }
}

public struct SyncPlan: Sendable, Equatable {
    public var items: [SyncItem]
    public var options: SyncOptions

    public var adds: Int { items.filter { $0.included && $0.reason == "new" && !$0.isDirectory }.count }
    public var updates: Int { items.filter { $0.included && $0.isChange && !$0.isDelete && $0.reason != "new" && !$0.isDirectory }.count }
    public var deletes: Int { items.filter { $0.included && $0.isDelete }.count }
    public var conflicts: Int { items.filter { if case .conflict = $0.action { return true }; return false }.count }
    public var same: Int { items.filter { $0.action == .same }.count }
    public var bytes: UInt64 { items.filter(\.included).reduce(0) { $0 + $1.bytes } }
    public var hasChanges: Bool { items.contains { $0.included && $0.isChange } }
}

public struct SyncResult: Sendable, Equatable {
    public var done = 0
    public var failures: [BatchProgress.Failure] = []
}

public enum SyncEngine {
    // MARK: Compare

    public static func compare(left: FileSystemOps, leftRoot: String, right: FileSystemOps, rightRoot: String,
                               options: SyncOptions,
                               progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> SyncPlan {
        guard options.isValid else { throw SyncError.twoWayDelete }
        var items: [SyncItem] = []
        var compared = 0
        try await walk("", leftRoot, rightRoot, left, right, options, &items, &compared, progress)
        if options.skipEmptyFolders { items = dropEmptyFolderCreations(items) }
        return SyncPlan(items: items, options: options)
    }

    /// Unicode-normalised key: macOS (NFD) and Linux (usually NFC) spell "café" differently.
    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    static func excluded(_ name: String, _ relative: String, _ o: SyncOptions) -> Bool {
        if !o.includeHidden && name.hasPrefix(".") { return true }
        if name.hasSuffix(partialSuffix) { return true }
        return o.excludes.contains { pattern in
            fnmatch(pattern, name, 0) == 0 || fnmatch(pattern, relative, 0) == 0
        }
    }

    private static func walk(_ relative: String, _ lPath: String, _ rPath: String,
                             _ left: FileSystemOps, _ right: FileSystemOps, _ o: SyncOptions,
                             _ items: inout [SyncItem], _ compared: inout Int,
                             _ progress: @escaping @Sendable (Int) -> Void) async throws {
        try Task.checkCancellation()
        async let lList = left.list(lPath)
        async let rList = right.list(rPath)
        let lEntries = try await lList, rEntries = try await rList
        var lByKey: [String: FileEntry] = [:], rByKey: [String: FileEntry] = [:]
        for e in lEntries { lByKey[key(e.name)] = e }
        for e in rEntries { rByKey[key(e.name)] = e }
        let keys = Set(lByKey.keys).union(rByKey.keys).sorted()

        for k in keys {
            let l = lByKey[k], r = rByKey[k]
            let name = (l ?? r)!.name
            let rel = relative.isEmpty ? name : relative + "/" + name
            if excluded(name, rel, o) { continue }
            compared += 1
            if compared % 50 == 0 { progress(compared) }
            let lDir = l?.isDirectory ?? false, rDir = r?.isDirectory ?? false

            switch (l, r) {
            case let (l?, r?) where lDir && rDir:
                if o.subfolders {
                    try await walk(rel, l.path, r.path, left, right, o, &items, &compared, progress)
                }
            case let (l?, r?) where lDir != rDir:
                items.append(SyncItem(relativePath: rel, isDirectory: lDir, left: l.attributes, right: r.attributes,
                                      action: .conflict("A file on one side and a folder on the other"), reason: "", included: false))
            case let (l?, r?):
                items.append(compareFiles(rel, l.attributes, r.attributes, o))
            case let (l?, nil):
                try await onlyOneSide(rel, l, side: .left, ops: left, o, &items, &compared, progress)
            case let (nil, r?):
                try await onlyOneSide(rel, r, side: .right, ops: right, o, &items, &compared, progress)
            case (nil, nil):
                break
            }
        }
    }

    enum Side { case left, right }

    /// Something exists on one side only: an add (towards the other side) or an orphan (to delete).
    private static func onlyOneSide(_ rel: String, _ e: FileEntry, side: Side, ops: FileSystemOps, _ o: SyncOptions,
                                    _ items: inout [SyncItem], _ compared: inout Int,
                                    _ progress: @escaping @Sendable (Int) -> Void) async throws {
        let isSource = o.direction == .both || (side == .left ? o.direction == .leftToRight : o.direction == .rightToLeft)
        let isDir = e.isDirectory
        let l = side == .left ? e.attributes : nil, r = side == .right ? e.attributes : nil
        if isSource {
            guard o.addMissing else { return }
            if isDir {
                guard o.subfolders else { return }
                items.append(SyncItem(relativePath: rel, isDirectory: true, left: l, right: r,
                                      action: side == .left ? .createFolderRight : .createFolderLeft, reason: "new", included: true))
                for child in try await ops.list(e.path).sorted(by: { $0.name < $1.name }) {
                    let childRel = rel + "/" + child.name
                    if excluded(child.name, childRel, o) { continue }
                    compared += 1
                    try await onlyOneSide(childRel, child, side: side, ops: ops, o, &items, &compared, progress)
                }
            } else {
                items.append(SyncItem(relativePath: rel, isDirectory: false, left: l, right: r,
                                      action: side == .left ? .copyToRight : .copyToLeft, reason: "new", included: true))
            }
        } else if o.deleteOrphans {
            items.append(SyncItem(relativePath: rel, isDirectory: isDir, left: l, right: r,
                                  action: side == .left ? .deleteLeft : .deleteRight, reason: "not in source", included: true))
        }
    }

    static func compareFiles(_ rel: String, _ l: FileAttributes, _ r: FileAttributes, _ o: SyncOptions) -> SyncItem {
        let lt = Int(l.modificationTime ?? 0), rt = Int(r.modificationTime ?? 0) + o.timeOffset
        let leftNewer = lt - rt > o.tolerance, rightNewer = rt - lt > o.tolerance
        let sizeDiffers = l.size != r.size
        let differs: Bool = switch o.updateBy {
        case .date: leftNewer || rightNewer
        case .size: sizeDiffers
        case .dateOrSize: leftNewer || rightNewer || sizeDiffers
        case .never: false
        }
        func item(_ a: SyncItem.Action, _ reason: String, _ included: Bool = true) -> SyncItem {
            SyncItem(relativePath: rel, isDirectory: false, left: l, right: r, action: a, reason: reason, included: included)
        }
        guard differs else { return item(.same, "", false) }
        let why = (leftNewer || rightNewer) ? "newer" : "different size"
        switch o.direction {
        case .leftToRight:
            if rightNewer { return item(.conflict("The copy on the right is newer"), "", false) }
            return item(.copyToRight, why)
        case .rightToLeft:
            if leftNewer { return item(.conflict("The copy on the left is newer"), "", false) }
            return item(.copyToLeft, why)
        case .both:
            if leftNewer { return item(.copyToRight, "newer") }
            if rightNewer { return item(.copyToLeft, "newer") }
            return item(.conflict("Changed on both sides at the same time"), "", false)
        }
    }

    /// Drops "create folder" items for folders that would end up with no files.
    static func dropEmptyFolderCreations(_ items: [SyncItem]) -> [SyncItem] {
        let filePaths = items.filter { !$0.isDirectory && ($0.action == .copyToRight || $0.action == .copyToLeft) }.map(\.relativePath)
        return items.filter { item in
            guard item.action == .createFolderRight || item.action == .createFolderLeft else { return true }
            return filePaths.contains { $0.hasPrefix(item.relativePath + "/") }
        }
    }

    // MARK: Execute

    /// Runs the ticked items: folders first (parents before children), then files (`parallel` at a time),
    /// then deletions (deepest first). Keeps going past single failures and reports them.
    public static func execute(_ plan: SyncPlan, left: FileSystemOps, leftRoot: String, right: FileSystemOps, rightRoot: String,
                               parallel: Int = 3,
                               progress: @escaping @Sendable (_ done: Int, _ total: Int, _ current: String) -> Void = { _, _, _ in }) async -> SyncResult {
        let todo = plan.items.filter { $0.included && $0.isChange }
        let total = todo.count
        let state = ResultBox()
        func path(_ root: String, _ rel: String) -> String { RemotePath.join(root, rel) }
        func record(_ rel: String, _ error: Error?) {
            let n = state.finish(rel, error)
            progress(n, total, rel)
        }

        // 1. folders
        for item in todo.filter({ $0.action == .createFolderRight || $0.action == .createFolderLeft })
            .sorted(by: { $0.relativePath.count < $1.relativePath.count }) {
            if Task.isCancelled { return state.result }
            let (ops, p) = item.action == .createFolderRight ? (right, path(rightRoot, item.relativePath)) : (left, path(leftRoot, item.relativePath))
            do {
                if try await ops.lstat(p) == nil { try await ops.mkdir(p) }
                record(item.relativePath, nil)
            } catch { record(item.relativePath, error) }
        }

        // 2. files
        let copies = todo.filter { $0.action == .copyToRight || $0.action == .copyToLeft }
        await withTaskGroup(of: Void.self) { group in
            var queue = copies[...]
            var running = 0
            while !queue.isEmpty || running > 0 {
                while running < max(1, parallel), let item = queue.popFirst() {
                    running += 1
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        let toRight = item.action == .copyToRight
                        let (from, to) = toRight ? (left, right) : (right, left)
                        let src = path(toRight ? leftRoot : rightRoot, item.relativePath)
                        let dst = path(toRight ? rightRoot : leftRoot, item.relativePath)
                        let attrs = (toRight ? item.left : item.right) ?? FileAttributes()
                        let entry = FileEntry(name: (src as NSString).lastPathComponent, path: src, attributes: attrs)
                        do {
                            try await transferFile(entry, from: from, to: to, destination: dst)
                            record(item.relativePath, nil)
                        } catch { record(item.relativePath, error) }
                    }
                }
                await group.next()
                running -= 1
            }
        }

        // 3. deletions, deepest first
        for item in todo.filter(\.isDelete).sorted(by: { $0.relativePath.count > $1.relativePath.count }) {
            if Task.isCancelled { return state.result }
            let (ops, p) = item.action == .deleteRight ? (right, path(rightRoot, item.relativePath)) : (left, path(leftRoot, item.relativePath))
            do {
                try await deleteTree(at: p, on: ops)
                record(item.relativePath, nil)
            } catch { record(item.relativePath, error) }
        }
        return state.result
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var r = SyncResult()
        var result: SyncResult { lock.withLock { r } }
        func finish(_ rel: String, _ error: Error?) -> Int {
            lock.withLock {
                r.done += 1
                if let error { r.failures.append(.init(path: rel, message: error.localizedDescription)) }
                return r.done
            }
        }
    }
}

public enum SyncError: Error, LocalizedError, Equatable {
    case twoWayDelete
    public var errorDescription: String? {
        "Two-way sync can't delete items: Shellpane couldn't tell a deletion from a file that was never there."
    }
}
