import CryptoKit
import Foundation
import SFTPKit

/// F05: a remote file opened in a local editor. Download to a private temp folder, then on every save
/// upload it back, unless someone else changed the file on the server meanwhile.
public final class RemoteEditSession: @unchecked Sendable {
    public enum UploadResult: Equatable, Sendable {
        case uploaded
        case unchanged
        /// The server's copy changed since we downloaded it. Nothing was uploaded.
        case remoteChanged
    }

    public let remotePath: String
    public let localURL: URL
    private let client: SFTPClient
    private let lock = NSLock()
    private var remoteMTime: UInt32?
    private var remoteSize: UInt64?
    private var lastUploadedHash: String?

    public static func open(_ remotePath: String, client: SFTPClient, editRoot: URL) async throws -> RemoteEditSession {
        let dir = editRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let local = dir.appendingPathComponent((remotePath as NSString).lastPathComponent)
        try await client.download(remotePath, to: local)
        let attrs = try await client.stat(remotePath)
        let session = RemoteEditSession(remotePath: remotePath, localURL: local, client: client)
        session.remoteMTime = attrs.modificationTime
        session.remoteSize = attrs.size
        session.lastUploadedHash = try Self.hash(local)
        return session
    }

    private init(remotePath: String, localURL: URL, client: SFTPClient) {
        self.remotePath = remotePath
        self.localURL = localURL
        self.client = client
    }

    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    /// Call after the local file changed. `force` uploads even if the server copy moved on (the person chose "Replace").
    public func uploadIfChanged(force: Bool = false) async throws -> UploadResult {
        let hash = try Self.hash(localURL)
        let (known, mtime, size) = lock.withLock { (lastUploadedHash, remoteMTime, remoteSize) }
        if hash == known && !force { return .unchanged }
        if !force {
            let now = try? await client.stat(remotePath)
            if let now, now.modificationTime != mtime || now.size != size { return .remoteChanged }
        }
        try await client.upload(localURL, to: remotePath)
        let after = try await client.stat(remotePath)
        lock.withLock {
            lastUploadedHash = hash
            remoteMTime = after.modificationTime
            remoteSize = after.size
        }
        return .uploaded
    }

    /// Drops the local copy.
    public func close() {
        try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
    }
}
