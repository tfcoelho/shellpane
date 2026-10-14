import AppKit
import ShellpaneCore
import SFTPKit
import TransferKit

/// F05: open a remote file in the person's own editor; every save goes back to the server.
/// Watches by polling size + modification time once a second: works with every editor's save style
/// (in place, atomic rename, delete-and-recreate) where file-system events miss some.
@MainActor
final class RemoteEditManager {
    static let shared = RemoteEditManager()

    struct Open {
        let session: RemoteEditSession
        let remote: RemoteSession
        var lastSeen: (Date?, Int?)
        var busy = false
    }

    private var open: [String: Open] = [:]   // key: session key + remote path
    private var timer: Timer?
    var onStatus: (String) -> Void = { _ in }
    /// (folder, filesystem identity) of a file that was just uploaded, so panes showing it can refresh.
    var onUploaded: (String, String) -> Void = { _, _ in }

    static var editRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Shellpane/Edits", isDirectory: true)
    }

    /// Leftovers from a previous run (crash, force quit) whose edits were all uploaded or abandoned.
    static func cleanUpOldCopies() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: editRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        for dir in dirs {
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < weekAgo { try? fm.removeItem(at: dir) }
        }
    }

    func edit(_ entry: FileEntry, on remote: RemoteSession, with app: URL? = nil) async throws {
        let key = remote.key + "\u{0}" + entry.path
        if let existing = open[key] {
            openLocally(existing.session.localURL, with: app)
            return
        }
        let s = try await RemoteEditSession.open(entry.path, client: remote.client, editRoot: Self.editRoot)
        open[key] = Open(session: s, remote: remote, lastSeen: Self.stamp(s.localURL))
        openLocally(s.localURL, with: app)
        startTimer()
        onStatus("Editing \(entry.name). Saves upload to \(remote.label) automatically.")
    }

    private func openLocally(_ url: URL, with app: URL?) {
        // Scripted checks edit the local copy themselves; don't launch an editor on the person's screen.
        if ProcessInfo.processInfo.environment["SHELLPANE_EDIT_NO_OPEN"] == "1" { return }
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    var openCount: Int { open.count }

    func stopAll() {
        for o in open.values { o.session.close() }
        open.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private static func stamp(_ url: URL) -> (Date?, Int?) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate, v?.fileSize)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        for (key, o) in open where !o.busy {
            let now = Self.stamp(o.session.localURL)
            guard now.0 != nil, now.0 != o.lastSeen.0 || now.1 != o.lastSeen.1 else { continue }
            open[key]?.lastSeen = now
            open[key]?.busy = true
            Task { await upload(key) }
        }
    }

    private func upload(_ key: String, force: Bool = false) async {
        guard let o = open[key] else { return }
        defer { open[key]?.busy = false }
        let name = (o.session.remotePath as NSString).lastPathComponent
        do {
            _ = try await o.remote.live()  // reconnect first if the connection dropped
            switch try await o.session.uploadIfChanged(force: force) {
            case .uploaded:
                onStatus("Saved \(name) to \(o.remote.label).")
                ConnectionManager.shared.log.record(.editUpload, path: o.session.remotePath, favoriteID: o.remote.key)
                onUploaded((o.session.remotePath as NSString).deletingLastPathComponent, o.remote.ops.identity)
            case .unchanged: break
            case .remoteChanged:
                if await askOverwrite(name, server: o.remote.label) {
                    open[key]?.busy = false
                    await upload(key, force: true)
                } else {
                    onStatus("Not uploaded: \(name) changed on \(o.remote.label). Your copy is still open.")
                }
            }
        } catch {
            onStatus("Couldn't save \(name) to \(o.remote.label): \(error.localizedDescription) Shellpane will try again on your next save.")
            ConnectionManager.shared.log.record(.editUpload, path: o.session.remotePath, result: .failed, message: error.localizedDescription, favoriteID: o.remote.key)
        }
    }

    private func askOverwrite(_ name: String, server: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” changed on \(server)"
        alert.informativeText = "Someone or something changed the file on the server since you opened it. Uploading your version replaces those changes."
        alert.addButton(withTitle: "Keep Server Version")
        alert.addButton(withTitle: "Upload Mine Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
