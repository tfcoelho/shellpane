import AppKit
import Quartz
import SFTPKit

/// F3 (or Space with Commander keys off): Quick Look the selection. Server files are downloaded first
/// to a private cache folder (up to 5 files, each under 200 MB), then shown by the system's panel.
@MainActor
final class QuickLookCenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookCenter()
    /// Read by the panel from outside the main actor, so it lives behind a lock.
    private let box = URLBox()
    var urls: [URL] { box.urls }

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("Shellpane/QuickLook", isDirectory: true)
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { NSSound.beep(); return }
        box.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle(_ urls: () async -> [URL]) async {
        if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        show(await urls())
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { box.urls.count }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = box.urls
        return index < urls.count ? urls[index] as NSURL : nil
    }
}

extension PaneTableView {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLookCenter.shared }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

extension PaneViewController {
    /// The marked items, or the one under the cursor.
    private var actionTargets: [FileEntry] {
        let selected = selectedEntries
        if !selected.isEmpty { return selected }
        let c = tableView.cursor
        return c >= 0 && c < entries.count ? [entries[c]] : []
    }

    func quickLook() {
        let targets = actionTargets.filter { !$0.isDirectory }
        guard !targets.isEmpty else { NSSound.beep(); return }
        let loc = location
        Task { @MainActor in
            await QuickLookCenter.shared.toggle {
                switch loc {
                case .local:
                    return targets.map { URL(fileURLWithPath: $0.path) }
                case let .remote(session, _):
                    var urls: [URL] = []
                    guard let live = try? await session.live() else { return [] }
                    for e in targets.prefix(5) where (e.attributes.size ?? 0) < 200_000_000 {
                        let dir = QuickLookCenter.cacheRoot.appendingPathComponent(UUID().uuidString)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let dest = dir.appendingPathComponent(e.name)
                        self.flash("Fetching \\(e.name) for Quick Look…")
                        if (try? await live.client.download(e.path, to: dest)) != nil { urls.append(dest) }
                    }
                    return urls
                }
            }
        }
    }

    /// F4: edit the file under the cursor (in your editor; on a server, saves upload).
    func editSelected() {
        guard let e = actionTargets.first(where: { !$0.isDirectory }) else { NSSound.beep(); return }
        if case .local = location {
            NSWorkspace.shared.open(URL(fileURLWithPath: e.path))
        } else {
            editRemote(e, with: nil)
        }
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] {
        get { lock.withLock { _urls } }
        set { lock.withLock { _urls = newValue } }
    }
}
