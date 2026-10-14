import Foundation
import SFTPKit

public enum ConflictChoice: String, Sendable, CaseIterable {
    case replace, skip, keepBoth, replaceIfNewer, stop
}

public struct Conflict: Sendable {
    public let name: String
    public let destinationFolder: String
    public let existing: FileAttributes
    public let incoming: FileAttributes
    public let remaining: Int  // conflicts still possible after this one (files not yet checked)
}

public struct ConflictDecision: Sendable {
    public var choice: ConflictChoice
    public var applyToAll: Bool
    public init(_ choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct BatchProgress: Sendable, Equatable {
    public enum State: Sendable, Equatable { case planning, running, waitingForDecision, done, cancelled, failed(String) }
    public var state: State = .planning
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesDone: UInt64 = 0
    public var bytesTotal: UInt64 = 0
    public var currentName = ""
    public var skipped = 0
    public var failures: [Failure] = []

    public struct Failure: Sendable, Equatable {
        public let path: String
        public let message: String
    }
}

/// Copies or moves files and folders between two filesystems: plans the tree, creates folders,
/// copies files `parallel` at a time, asks about conflicts one at a time (and remembers "apply to all"),
/// keeps going past single failures and reports them at the end. Cancel by cancelling the running Task.
public final class TransferBatch: @unchecked Sendable {
    public enum Mode: Sendable { case copy, move }

    public let mode: Mode
    public let sources: [FileEntry]
    public let destinationFolder: String
    private let from: FileSystemOps
    private let to: FileSystemOps
    private let parallel: Int
    /// Files already at the destination with the same size and modification time are skipped without asking.
    /// Used when retrying after a dropped connection: copies keep the source's mtime, so finished files match.
    private let skipIdentical: Bool
    private let resolver: @Sendable (Conflict) async -> ConflictDecision
    private let onProgress: @Sendable (BatchProgress) -> Void
    private let gate = ConflictGate()
    private let pauseGate = PauseGate()

    /// Holds new files and the next chunk of files in flight until resume().
    public func pause() async { await pauseGate.pause() }
    public func resume() async { await pauseGate.resume() }
    private let lock = NSLock()
    private var progress = BatchProgress()
    private var inFlight: [String: UInt64] = [:]  // bytes so far of files being copied right now

    public init(mode: Mode, sources: [FileEntry], from: FileSystemOps, to: FileSystemOps, destinationFolder: String,
                parallel: Int = 3, skipIdentical: Bool = false,
                resolver: @escaping @Sendable (Conflict) async -> ConflictDecision,
                onProgress: @escaping @Sendable (BatchProgress) -> Void = { _ in }) {
        self.mode = mode
        self.sources = sources
        self.from = from
        self.to = to
        self.destinationFolder = destinationFolder
        self.parallel = max(1, parallel)
        self.skipIdentical = skipIdentical
        self.resolver = resolver
        self.onProgress = onProgress
    }

    public var snapshot: BatchProgress { lock.withLock { progress } }

    private func update(_ change: (inout BatchProgress) -> Void) {
        let p = lock.withLock { () -> BatchProgress in
            change(&progress)
            var p = progress
            p.bytesDone += inFlight.values.reduce(0, +)
            return p
        }
        onProgress(p)
    }

    // MARK: - Plan

    struct FileJob: Sendable {
        let source: FileEntry
        let destination: String   // full path
        let destinationFolder: String
    }

    struct Plan {
        var folders: [String] = []           // to create, parents first
        var folderTimes: [(String, UInt32)] = []  // destination folder → source folder's mtime
        var files: [FileJob] = []
        var sourceFoldersToRemove: [String] = []  // for moves, deepest first
    }

    /// Walks folders on the source side. Never copies a folder into itself.
    func plan() async throws -> Plan {
        var plan = Plan()
        for source in sources {
            try Task.checkCancellation()
            let dest = RemotePath.join(destinationFolder, source.name)
            if from.identity == to.identity, dest == source.path || (dest + "/").hasPrefix(source.path + "/") {
                throw TransferError.intoItself(source.name)
            }
            try await add(source, dest: dest, folder: destinationFolder, into: &plan)
        }
        return plan
    }

    private func add(_ entry: FileEntry, dest: String, folder: String, into plan: inout Plan) async throws {
        switch entry.attributes.fileType {
        case .directory:
            plan.folders.append(dest)
            if let t = entry.attributes.modificationTime { plan.folderTimes.append((dest, t)) }
            for child in try await from.list(entry.path).sorted(by: { $0.name < $1.name }) {
                try Task.checkCancellation()
                try await add(child, dest: RemotePath.join(dest, child.name), folder: dest, into: &plan)
            }
            if mode == .move { plan.sourceFoldersToRemove.insert(entry.path, at: 0) }
        case .symlink where entry.targetType == .directory:
            // Following folder links could loop forever; copy what they point to by opening the link itself.
            throw TransferError.folderLink(entry.name)
        default:
            plan.files.append(FileJob(source: entry, destination: dest, destinationFolder: folder))
        }
    }

    // MARK: - Run

    public func run() async {
        update { $0.state = .planning }
        do {
            // A move within one filesystem is a rename: instant, whatever the size.
            if mode == .move, from.identity == to.identity {
                try await renameAll()
                return
            }
            let plan = try await plan()
            let total = plan.files.reduce(UInt64(0)) { $0 + ($1.source.attributes.size ?? 0) }
            update {
                $0.filesTotal = plan.files.count
                $0.bytesTotal = total
                $0.state = .running
            }
            for folder in plan.folders {
                try Task.checkCancellation()
                if try await to.lstat(folder) == nil { try await to.mkdir(folder) }
            }
            try await copyFiles(plan.files)
            // Folder dates last, deepest first: copying files into a folder changes its date.
            for (folder, time) in plan.folderTimes.reversed() {
                try? await to.setModificationTime(folder, time)
            }
            if mode == .move {
                for folder in plan.sourceFoldersToRemove {
                    try? await from.removeDirectory(folder)  // stays if something inside was skipped
                }
            }
            update { $0.state = $0.failures.isEmpty ? .done : .failed("\($0.failures.count) item\($0.failures.count == 1 ? "" : "s") couldn't be copied") }
        } catch is CancellationError {
            update { $0.state = .cancelled }
        } catch let SFTPError.connectionClosed(detail) {
            update { $0.state = .failed(detail) }
        } catch {
            update { $0.state = .failed(error.localizedDescription) }
        }
    }

    private func renameAll() async throws {
        update {
            $0.filesTotal = sources.count
            $0.state = .running
        }
        for source in sources {
            try Task.checkCancellation()
            var dest = RemotePath.join(destinationFolder, source.name)
            if dest == source.path { update { $0.filesDone += 1; $0.skipped += 1 }; continue }
            if (dest + "/").hasPrefix(source.path + "/") { throw TransferError.intoItself(source.name) }
            update { $0.currentName = source.name }
            if let existing = try await to.lstat(dest) {
                let decision = await decide(Conflict(name: source.name, destinationFolder: destinationFolder,
                                                     existing: existing, incoming: source.attributes, remaining: 0))
                switch decision {
                case .stop: throw CancellationError()
                case .skip: update { $0.filesDone += 1; $0.skipped += 1 }; continue
                case .replaceIfNewer where (source.attributes.modificationTime ?? 0) <= (existing.modificationTime ?? 0):
                    update { $0.filesDone += 1; $0.skipped += 1 }; continue
                case .keepBoth:
                    dest = RemotePath.join(destinationFolder, try await FileNames.uniqueName(source.name) { try await to.lstat(RemotePath.join(destinationFolder, $0)) != nil })
                default:
                    if existing.fileType == .directory {
                        try await deleteTree(at: dest, on: to)
                    } else {
                        try await to.removeFile(dest)
                    }
                }
            }
            do {
                try await from.rename(source.path, to: dest)
            } catch {
                update { $0.failures.append(.init(path: source.path, message: error.localizedDescription)) }
            }
            update { $0.filesDone += 1 }
        }
        update { $0.state = $0.failures.isEmpty ? .done : .failed("\($0.failures.count) item\($0.failures.count == 1 ? "" : "s") couldn't be moved") }
    }

    private func copyFiles(_ files: [FileJob]) async throws {
        var queue = files[...]
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            while !queue.isEmpty || running > 0 {
                while running < parallel, let job = queue.popFirst() {
                    group.addTask { try await self.copy(job) }
                    running += 1
                }
                try await group.next()
                running -= 1
            }
        }
    }

    private func decide(_ conflict: Conflict) async -> ConflictChoice {
        await gate.decide(conflict) { [self] c in
            self.update { $0.state = .waitingForDecision }
            let d = await self.resolver(c)
            self.update { $0.state = .running }
            return d
        }
    }

    private func copy(_ job: FileJob) async throws {
        await pauseGate.wait()
        try Task.checkCancellation()
        let name = job.source.name
        update { $0.currentName = name }
        var destination = job.destination
        let size = job.source.attributes.size ?? 0

        if let existing = try await to.lstat(destination) {
            if skipIdentical, existing.fileType != .directory, existing.size == job.source.attributes.size,
               existing.modificationTime == job.source.attributes.modificationTime {
                update { $0.filesDone += 1; $0.skipped += 1; $0.bytesDone += size }
                return
            }
            let remaining = lock.withLock { progress.filesTotal - progress.filesDone - 1 }
            let choice = await decide(Conflict(name: name, destinationFolder: job.destinationFolder,
                                               existing: existing, incoming: job.source.attributes, remaining: remaining))
            switch choice {
            case .stop:
                throw CancellationError()
            case .skip:
                update { $0.filesDone += 1; $0.skipped += 1; $0.bytesDone += size }
                return
            case .replaceIfNewer where (job.source.attributes.modificationTime ?? 0) <= (existing.modificationTime ?? 0):
                update { $0.filesDone += 1; $0.skipped += 1; $0.bytesDone += size }
                return
            case .keepBoth:
                let folder = job.destinationFolder
                let unique = try await FileNames.uniqueName(name) { try await to.lstat(RemotePath.join(folder, $0)) != nil }
                destination = RemotePath.join(folder, unique)
            case .replace, .replaceIfNewer:
                if existing.fileType == .directory {
                    update { $0.failures.append(.init(path: destination, message: "A folder with this name is in the way.")); $0.filesDone += 1 }
                    return
                }
            }
        }

        do {
            try await transfer(job.source, to: destination)
            lock.withLock { inFlight[job.source.path] = nil }
            update { $0.filesDone += 1; $0.bytesDone += size }
            if mode == .move { try? await from.removeFile(job.source.path) }
        } catch let error as SFTPError where error.isConnectionLoss {
            throw error  // the whole batch stops; nothing else will work either
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lock.withLock { inFlight[job.source.path] = nil }
            update {
                $0.failures.append(.init(path: job.source.path, message: error.localizedDescription))
                $0.filesDone += 1
                $0.bytesDone += size
            }
        }
    }

    private func transfer(_ source: FileEntry, to destination: String) async throws {
        let key = source.path
        let pauseGate = pauseGate
        try await transferFile(source, from: from, to: to, destination: destination, progress: { [weak self] done, _ in
            guard let self else { return }
            self.lock.withLock { self.inFlight[key] = done }
            self.update { _ in }
        }, throttle: { _ in await pauseGate.wait() })
    }
}

/// Copies one file between any two places (Mac or server, either side). Writes to a temporary name and
/// renames at the end, so a half-done copy never sits under the real name. Keeps the modification time.
/// Downloads and uploads go through the shared bandwidth limiters, then `throttle` (e.g. a pause gate).
public func transferFile(_ source: FileEntry, from: FileSystemOps, to: FileSystemOps, destination: String,
                         progress: @escaping ProgressHandler = { _, _ in },
                         throttle: Throttle? = nil) async throws {
    let down: Throttle = { n in await BandwidthLimiter.downloads.take(n); await throttle?(n) }
    let up: Throttle = { n in await BandwidthLimiter.uploads.take(n); await throttle?(n) }
    switch (from, to) {
    case let (f as RemoteOps, _ as LocalOps):
        try await f.client.download(source.path, to: URL(fileURLWithPath: destination), progress: progress, throttle: down)
    case let (_ as LocalOps, t as RemoteOps):
        try await t.client.upload(URL(fileURLWithPath: source.path), to: destination, progress: progress, throttle: up)
    case (_ as LocalOps, _ as LocalOps):
        let part = RemotePath.join(RemotePath.parent(destination), partialName(for: (destination as NSString).lastPathComponent))
        try? FileManager.default.removeItem(atPath: part)
        try FileManager.default.copyItem(atPath: source.path, toPath: part)
        if FileManager.default.fileExists(atPath: destination) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: part))
        } else {
            try FileManager.default.moveItem(atPath: part, toPath: destination)
        }
        progress(source.attributes.size ?? 0, source.attributes.size)
    case let (f as RemoteOps, t as RemoteOps):
        // Through a temp file on this Mac: works between any two servers.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let size = source.attributes.size ?? 0
        try await f.client.download(source.path, to: temp, progress: { done, _ in progress(done / 2, size) }, throttle: down)
        try await t.client.upload(temp, to: destination, progress: { done, _ in progress(size / 2 + done / 2, size) }, throttle: up)
    default:
        throw TransferError.unsupported
    }
}

/// One conflict question at a time; once someone ticks "apply to all", later conflicts don't ask.
/// Actors are re-entrant at `await`, so a plain "check, then ask" would let parallel copies open several
/// questions at once. Instead, whoever finds a question open waits for it and then checks again.
actor ConflictGate {
    private var remembered: ConflictChoice?
    private var open: (id: Int, task: Task<ConflictDecision, Never>)?
    private var nextID = 0

    func decide(_ conflict: Conflict, ask: @escaping @Sendable (Conflict) async -> ConflictDecision) async -> ConflictChoice {
        while true {
            if let remembered { return remembered }
            if let current = open {
                // Wait for the open question. Whoever resumes first (asker or waiter) records the answer
                // and clears it; otherwise waiters would spin on a finished task the asker hasn't cleared yet.
                let d = await current.task.value
                finish(current.id, d)
                continue
            }
            nextID += 1
            let id = nextID
            let question = Task { await ask(conflict) }
            open = (id, question)
            let d = await question.value
            finish(id, d)
            return d.choice
        }
    }

    private func finish(_ id: Int, _ d: ConflictDecision) {
        guard open?.id == id else { return }
        if d.applyToAll || d.choice == .stop { remembered = d.choice }
        open = nil
    }
}

public enum TransferError: Error, LocalizedError, Equatable {
    case intoItself(String)
    case folderLink(String)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case let .intoItself(name): "“\(name)” can't be copied or moved into itself."
        case let .folderLink(name): "“\(name)” is a link to a folder. Open it and copy what's inside instead."
        case .unsupported: "Shellpane can't copy between these two places yet."
        }
    }
}

extension SFTPError {
    var isConnectionLoss: Bool {
        if case .connectionClosed = self { return true }
        return false
    }
}

/// Deletes a file or a whole folder tree. Remote deletes are permanent; callers confirm first.
public func deleteTree(at path: String, on ops: FileSystemOps) async throws {
    guard let attrs = try await ops.lstat(path) else { return }
    if attrs.fileType == .directory {
        for child in try await ops.list(path) {
            try Task.checkCancellation()
            try await deleteTree(at: child.path, on: ops)
        }
        try await ops.removeDirectory(path)
    } else {
        try await ops.removeFile(path)
    }
}
