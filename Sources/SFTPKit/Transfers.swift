import Foundation

public typealias ProgressHandler = @Sendable (_ bytesDone: UInt64, _ bytesTotal: UInt64?) -> Void

/// Called with each chunk's size before more is requested. Bandwidth limits sleep here; pause waits here.
public typealias Throttle = @Sendable (_ bytes: Int) async -> Void

/// Suffix for files being transferred. They become the real name only when complete,
/// so a half-finished transfer never looks like a finished one.
public let partialSuffix = ".shellpane-part"

/// The temporary name used while `name` is being transferred. Stays within the 255-byte name limit:
/// a long name is shortened (on a character boundary) and tagged with a short hash so it stays unique.
public func partialName(for name: String) -> String {
    let plain = name + partialSuffix
    guard plain.utf8.count > 255 else { return plain }
    var hash: UInt32 = 2_166_136_261  // FNV-1a
    for b in name.utf8 { hash = (hash ^ UInt32(b)) &* 16_777_619 }
    let tag = "~" + String(format: "%08x", hash)
    let budget = 255 - partialSuffix.utf8.count - tag.utf8.count
    var stem = ""
    for ch in name {
        if stem.utf8.count + String(ch).utf8.count > budget { break }
        stem.append(ch)
    }
    return stem + tag + partialSuffix
}

extension SFTPClient {
    /// Downloads with up to `pipelineDepth` reads in flight. Writes to `<dest>.shellpane-part`,
    /// then moves it over `localURL` and copies the remote modification time.
    public func download(_ remotePath: String, to localURL: URL, progress: ProgressHandler = { _, _ in },
                         throttle: Throttle? = nil) async throws {
        let handle = try await open(remotePath, flags: .read)
        let partURL = localURL.deletingLastPathComponent().appendingPathComponent(partialName(for: localURL.lastPathComponent))
        do {
            let attrs = try await fstat(handle)
            let total = attrs.size
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let file = try FileHandle(forWritingTo: partURL)
            defer { try? file.close() }

            var done: UInt64 = 0
            progress(0, total)
            try await withThrowingTaskGroup(of: (UInt64, UInt32, Data?).self) { group in
                var next: UInt64 = 0
                var inFlight = 0
                var eofAt: UInt64?
                let chunk = Self.chunkSize

                func limit() -> UInt64? { [total, eofAt].compactMap { $0 }.min() }

                while inFlight < Self.pipelineDepth, limit().map({ next < $0 }) ?? true {
                    let offset = next
                    group.addTask { (offset, chunk, try await self.read(handle, offset: offset, length: chunk)) }
                    next += UInt64(chunk)
                    inFlight += 1
                }
                while let (offset, asked, data) = try await group.next() {
                    inFlight -= 1
                    try Task.checkCancellation()
                    if let data, !data.isEmpty {
                        try file.seek(toOffset: offset)
                        try file.write(contentsOf: data)
                        done += UInt64(data.count)
                        progress(done, total)
                        if let throttle { await throttle(data.count) }
                        if data.count < Int(asked) {  // short read: ask for the rest of this chunk
                            let rest = offset + UInt64(data.count)
                            let len = asked - UInt32(data.count)
                            group.addTask { (rest, len, try await self.read(handle, offset: rest, length: len)) }
                            inFlight += 1
                        }
                    } else {
                        eofAt = min(eofAt ?? offset, offset)
                    }
                    while inFlight < Self.pipelineDepth, limit().map({ next < $0 }) ?? true {
                        let o = next
                        group.addTask { (o, chunk, try await self.read(handle, offset: o, length: chunk)) }
                        next += UInt64(chunk)
                        inFlight += 1
                    }
                }
            }
            try? await close(handle)
            try file.truncate(atOffset: done)
            try file.close()

            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: partURL)
            } else {
                try FileManager.default.moveItem(at: partURL, to: localURL)
            }
            if let date = attrs.modificationDate {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: localURL.path)
            }
        } catch {
            try? await close(handle)
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
    }

    /// Uploads with up to `pipelineDepth` writes in flight to `<dest>.shellpane-part`, then renames it
    /// over `remotePath` and copies the local modification time and permissions.
    public func upload(_ localURL: URL, to remotePath: String, progress: ProgressHandler = { _, _ in },
                       throttle: Throttle? = nil) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let total = UInt64(values.fileSize ?? 0)
        let posix = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.posixPermissions] as? NSNumber)?.uint32Value
        let partPath = RemotePath.join(RemotePath.parent(remotePath), partialName(for: (remotePath as NSString).lastPathComponent))
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }

        let handle = try await open(partPath, flags: [.write, .create, .truncate],
                                    attributes: FileAttributes(permissions: posix.map { $0 & 0o777 }))
        do {
            var done: UInt64 = 0
            progress(0, total)
            try await withThrowingTaskGroup(of: Int.self) { group in
                var offset: UInt64 = 0
                var inFlight = 0
                while true {
                    while inFlight < Self.pipelineDepth {
                        guard let data = try file.read(upToCount: Int(Self.chunkSize)), !data.isEmpty else { break }
                        let o = offset
                        group.addTask { try await self.write(handle, offset: o, data: data); return data.count }
                        offset += UInt64(data.count)
                        inFlight += 1
                    }
                    guard let written = try await group.next() else { break }
                    inFlight -= 1
                    try Task.checkCancellation()
                    done += UInt64(written)
                    progress(done, total)
                    if let throttle { await throttle(written) }
                }
            }
            try await close(handle)
            try await posixRename(partPath, to: remotePath)
            if let date = values.contentModificationDate {
                let t = UInt32(clamping: Int(date.timeIntervalSince1970))
                try? await setstat(remotePath, FileAttributes(accessTime: t, modificationTime: t))
            }
        } catch {
            try? await close(handle)
            try? await remove(partPath)
            throw error
        }
    }
}
