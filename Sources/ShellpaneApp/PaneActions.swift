import AppKit
import ShellpaneUI
import SFTPKit
import ShellpaneCore
import TransferKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Files dragged or copied between Shellpane panes: {"pane": UUID, "paths": [String]}.
    static let shellpaneEntries = NSPasteboard.PasteboardType("app.shellpane.entries")
}

/// What ⌘C put on the clipboard, so ⌘V in a pane can copy it (local files also go on the
/// general pasteboard as file URLs, so pasting in Finder works too).
@MainActor
final class AppClipboard {
    static let shared = AppClipboard()
    var entries: [FileEntry] = []
    var location: Location?
    var changeCount = -1
}

// MARK: - File operations (F07) and clipboard

extension PaneViewController {
    func copyToClipboard() {
        let selected = selectedEntries
        guard !selected.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if case .local = location {
            pb.writeObjects(selected.map { URL(fileURLWithPath: $0.path) as NSURL })
        } else {
            pb.setString(selected.map(\.path).joined(separator: "\n"), forType: .string)
        }
        AppClipboard.shared.entries = selected
        AppClipboard.shared.location = location
        AppClipboard.shared.changeCount = pb.changeCount
        flash(selected.count == 1 ? "Copied “\(selected[0].name)”. Paste with ⌘V in the other pane."
                                  : "Copied \(selected.count) items. Paste with ⌘V in the other pane.")
    }

    func pasteFromClipboard() {
        guard acceptsNewItems() else { return }
        let pb = NSPasteboard.general
        let clip = AppClipboard.shared
        if pb.changeCount == clip.changeCount, let source = clip.location, !clip.entries.isEmpty {
            startTransfer(.copy, clip.entries, from: source, into: location)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            startTransfer(.copy, Self.localEntries(urls), from: .local("/"), into: location)
        } else {
            NSSound.beep()
        }
    }

    func startTransfer(_ mode: TransferBatch.Mode, _ entries: [FileEntry], from source: Location, into dest: Location) {
        guard !entries.isEmpty else { return }
        let sourceIdentity = source.ops.identity
        let sourceFolders = Set(entries.map { RemotePath.parent($0.path) })
        TransferCenter.shared.start(mode, entries, from: source, to: dest) { [weak self] in
            guard let self else { return }
            self.delegate?.folderChanged(dest.path, identity: dest.ops.identity)
            if mode == .move {
                for folder in sourceFolders { self.delegate?.folderChanged(folder, identity: sourceIdentity) }
            }
        }
    }

    static func localEntries(_ urls: [URL]) -> [FileEntry] {
        urls.compactMap { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            var a = FileAttributes()
            a.size = (attrs?[.size] as? NSNumber)?.uint64Value
            let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
            a.permissions = (isDir ? 0o040000 : 0o100000) | ((attrs?[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644)
            if let d = attrs?[.modificationDate] as? Date { a.modificationTime = UInt32(clamping: Int(d.timeIntervalSince1970)) }
            return FileEntry(name: url.lastPathComponent, path: url.path, attributes: a)
        }
    }

    /// Asks for a name in a sheet. Validates as you'd expect; returns nil on Cancel.
    func askName(title: String, message: String, initial: String, button: String) async -> String? {
        guard let window = view.window else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // Select the name without its extension, like Finder.
        let ext = (initial as NSString).pathExtension
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: ext.isEmpty ? initial.utf16.count : initial.utf16.count - ext.utf16.count - 1)
        }
        while true {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
            let name = field.stringValue
            if let problem = FileNames.validationError(for: name) {
                alert.informativeText = problem
                continue
            }
            return name
        }
    }

    func renameSelected() {
        guard let entry = selectedEntries.first, selectedEntries.count == 1 else { NSSound.beep(); return }
        Task { @MainActor in
            guard let name = await askName(title: "Rename “\(entry.name)”", message: "Enter a new name.",
                                           initial: entry.name, button: "Rename"), name != entry.name else { return }
            do {
                try await performRename(entry, to: name)
            } catch {
                showProblem("Couldn't rename “\(entry.name)”", error)
            }
        }
    }

    /// What Rename does after the dialog. Refuses to replace another item; a change of case only is allowed.
    func performRename(_ entry: FileEntry, to name: String) async throws {
        if let problem = FileNames.validationError(for: name) {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        let live = try await location.live()
        let target = RemotePath.join(RemotePath.parent(entry.path), name)
        let caseOnly = name.lowercased() == entry.name.lowercased()
        if !caseOnly, try await live.ops.lstat(target) != nil {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "“\(name)” already exists here. Pick another name."])
        }
        try await live.ops.rename(entry.path, to: target)
        ConnectionManager.shared.log.record(.rename, path: entry.path, message: "→ \(name)", favoriteID: live.session?.key)
        pendingSelection = name
        reload()
    }

    @objc func newFolder(_ sender: Any? = nil) {
        guard acceptsNewItems() else { return }
        Task { @MainActor in
            let ops = location.ops
            let folder = location.path
            let suggestion = (try? await FileNames.uniqueName("untitled folder") { try await ops.lstat(RemotePath.join(folder, $0)) != nil }) ?? "untitled folder"
            guard let name = await askName(title: "New Folder", message: "Name the new folder in “\(location.displayName)”.",
                                           initial: suggestion, button: "Create") else { return }
            do {
                try await performNewFolder(name)
            } catch {
                showProblem("Couldn't create “\(name)”", error)
            }
        }
    }

    /// What New Folder does after the dialog.
    func performNewFolder(_ name: String) async throws {
        if let problem = FileNames.validationError(for: name) {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        let live = try await location.live()
        try await live.ops.mkdir(RemotePath.join(location.path, name))
        ConnectionManager.shared.log.record(.mkdir, path: RemotePath.join(location.path, name), favoriteID: live.session?.key)
        pendingSelection = name
        reload()
    }

    /// What Delete does on a server after the person confirms. Returns what couldn't be deleted.
    func performRemoteDelete(_ targets: [FileEntry]) async -> [String] {
        var failures: [String] = []
        do {
            let live = try await location.live()
            for t in targets {
                do {
                    try await deleteTree(at: t.path, on: live.ops)
                    ConnectionManager.shared.log.record(.delete, path: t.path, favoriteID: live.session?.key)
                } catch {
                    failures.append("\(t.name): \(error.localizedDescription)")
                    ConnectionManager.shared.log.record(.delete, path: t.path, result: .failed, message: error.localizedDescription, favoriteID: live.session?.key)
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        reload()
        return failures
    }

    /// Local: to the Trash (undoable in Finder). Remote: permanent, so it asks first.
    func deleteSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty, let window = view.window else { NSSound.beep(); return }
        if case .local = location {
            var failed: [String] = []
            for t in targets {
                do {
                    try LocalOps().trash(t.path)
                    ConnectionManager.shared.log.record(.delete, path: t.path, message: "Moved to the Trash")
                } catch { failed.append(t.name) }
            }
            if !failed.isEmpty { showProblem("Couldn't move \(failed.joined(separator: ", ")) to the Trash", nil) }
            flash(targets.count == 1 ? "Moved “\(targets[0].name)” to the Trash." : "Moved \(targets.count) items to the Trash.")
            reload()
            return
        }
        guard let session = location.session else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1 ? "Delete “\(targets[0].name)” from \(session.label)?"
                                               : "Delete \(targets.count) items from \(session.label)?"
        let folders = targets.filter(\.isDirectory).count
        alert.informativeText = "Files on a server don't go to a Trash. This can't be undone."
            + (folders > 0 ? " Folders are deleted with everything inside them." : "")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\r"   // Return cancels; deleting takes a deliberate click
        alert.buttons[0].keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                self.showBusy("Deleting…")
                let failures = await self.performRemoteDelete(targets)
                self.showBusy(nil)
                if !failures.isEmpty {
                    self.showProblem("Some items couldn't be deleted", nil, details: failures.joined(separator: "\n"))
                } else {
                    self.flash(targets.count == 1 ? "Deleted “\(targets[0].name)”." : "Deleted \(targets.count) items.")
                }
            }
        }
    }

    /// F08: this folder (or the selected folder) in a terminal; on a server, logged in over ssh.
    @objc func openInTerminal(_ sender: Any? = nil) {
        openTerminal(in: nil)
    }

    @objc func openInTerminalApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let app = TerminalLauncher.known.first(where: { $0.bundleID == id }) else { return }
        TerminalLauncher.setPreferred(app)
        openTerminal(in: app)
    }

    private func openTerminal(in app: TerminalLauncher.App?) {
        let target = selectedEntries.count == 1 && selectedEntries[0].isDirectory ? location.with(path: selectedEntries[0].path) : location
        Task { @MainActor in
            do {
                try TerminalLauncher.open(try await target.live(), in: app)
            } catch {
                showProblem("Couldn't open a terminal", error)
            }
        }
    }

    @objc func copyPath(_ sender: Any? = nil) {
        let paths = selectedEntries.map(\.path)
        let text = paths.isEmpty ? location.path : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied the path.")
    }

    func editRemote(_ entry: FileEntry, with app: URL?) {
        guard let session = location.session else { return }
        flash("Opening \(entry.name)…")
        Task { @MainActor in
            do {
                try await RemoteEditManager.shared.edit(entry, on: try await session.live(), with: app)
            } catch {
                showProblem("Couldn't open “\(entry.name)”", error)
            }
        }
    }

    @objc func editWith(_ sender: Any? = nil) {
        guard let entry = selectedEntries.first, !entry.isDirectory else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an app to edit “\(entry.name)”"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let app = panel.url { editRemote(entry, with: app) }
    }

    func showProblem(_ title: String, _ error: Error?, details: String? = nil) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details ?? error?.localizedDescription ?? ""
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Context menu

extension PaneViewController: NSMenuDelegate {
    func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = viewMode == .list ? tableView.clickedRow : -1
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)  // right-click selects, like Finder
        }
        let selected = viewMode == .list ? (row >= 0 ? selectedEntries : []) : selectedEntries
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [], enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
        }
        if let first = selected.first {
            add("Open", #selector(openSelected))
            if isRemote && !first.isDirectory && selected.count == 1 {
                add("Edit With…", #selector(editWith(_:)))
            }
            menu.addItem(.separator())
            add("Copy to Other Pane", #selector(menuCopyToOther), String(UnicodeScalar(NSF5FunctionKey)!))
            add("Move to Other Pane", #selector(menuMoveToOther), String(UnicodeScalar(NSF6FunctionKey)!))
            add("Copy", #selector(menuClipboardCopy), "c", .command)
            menu.addItem(.separator())
            add("Rename…", #selector(menuRename), "\r", enabled: selected.count == 1)
        }
        add("New Folder…", #selector(newFolder(_:)), "n", [.command, .shift])
        let terminalTitle = "Open in \(TerminalLauncher.preferred.name)"
        add(terminalTitle, #selector(openInTerminal(_:)), "t", [.command, .option])
        if TerminalLauncher.installed.count > 1 {
            let others = NSMenuItem(title: "Open in", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for app in TerminalLauncher.installed {
                let i = NSMenuItem(title: app.name, action: #selector(openInTerminalApp(_:)), keyEquivalent: "")
                i.representedObject = app.bundleID
                i.target = self
                i.state = app == TerminalLauncher.preferred ? .on : .off
                sub.addItem(i)
            }
            others.submenu = sub
            menu.addItem(others)
        }
        add("Paste", #selector(menuPaste), "v", .command)
        add(selected.isEmpty ? "Copy Folder Path" : "Copy Path", #selector(copyPath(_:)), "c", [.command, .option])
        if selected.count == 1, selected[0].isDirectory {
            add("Add to Favorite Folders", #selector(menuAddBookmark))
        }
        if !selected.isEmpty {
            menu.addItem(.separator())
            add(isRemote ? "Delete…" : "Move to Trash", #selector(menuDelete), "\u{8}", .command)
        }
        menu.addItem(.separator())
        add("Reload", #selector(menuReload), "r", .command)
    }

    @objc private func menuCopyToOther() { delegate?.paneRequestsCopyToOtherPane(self) }
    @objc private func menuMoveToOther() { delegate?.paneRequestsMoveToOtherPane(self) }
    @objc private func menuClipboardCopy() { copyToClipboard() }
    @objc private func menuPaste() { pasteFromClipboard() }
    @objc private func menuRename() { renameSelected() }
    @objc private func menuDelete() { deleteSelected() }
    @objc private func menuReload() { reload() }
}

// MARK: - Drag and drop

/// A remote file dragged to Finder: Finder asks for it, we download it to where it was dropped.
final class RemotePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let entry: FileEntry
    let client: SFTPClient
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    init(entry: FileEntry, client: SFTPClient) {
        self.entry = entry
        self.client = client
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let entry = entry, client = client
        let done = DispatchSemaphore(value: 0)
        let result = ErrorBox()
        Task.detached {
            do {
                if entry.isDirectory {
                    // Copy the folder into a temp folder, then move it to exactly where Finder asked.
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-drop-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let batch = TransferBatch(mode: .copy, sources: [entry], from: RemoteOps(client: client, identity: "drop"),
                                              to: LocalOps(), destinationFolder: temp.path,
                                              resolver: { _ in .init(.replace, applyToAll: true) })
                    await batch.run()
                    if case let .failed(message) = batch.snapshot.state { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message]) }
                    try FileManager.default.moveItem(at: temp.appendingPathComponent(entry.name), to: url)
                } else {
                    try await client.download(entry.path, to: url)
                }
            } catch {
                result.error = error
            }
            done.signal()
        }
        done.wait()  // on our own operation queue, never the main thread
        completionHandler(result.error)
    }

    private final class ErrorBox: @unchecked Sendable { var error: Error? }
}

/// Carries both the Finder promise and Shellpane's own pane-to-pane payload.
final class ShellpanePromiseProvider: NSFilePromiseProvider {
    var shellpanePayload: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.shellpaneEntries]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .shellpaneEntries ? shellpanePayload : super.pasteboardPropertyList(forType: type)
    }
}

extension PaneViewController {
    func configureDragAndDrop() {
        tableView.registerForDraggedTypes([.shellpaneEntries, .fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
    }

    private func payload(_ paths: [String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["pane": paneID.uuidString, "paths": paths])
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        switch location {
        case .local:
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: entry.path).absoluteString, forType: .fileURL)
            item.setData(payload([entry.path]) ?? Data(), forType: .shellpaneEntries)
            return item
        case let .remote(session, _):
            let type = entry.isDirectory ? UTType.folder.identifier
                : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data).identifier
            let d = RemotePromiseDelegate(entry: entry, client: session.client)
            promiseDelegates.append(d)
            let provider = ShellpanePromiseProvider(fileType: type, delegate: d)
            provider.shellpanePayload = payload([entry.path])
            return provider
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedEntries = rowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Keep promise delegates alive a little longer: Finder may still be writing.
        let keep = promiseDelegates
        promiseDelegates = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { _ = keep }
        if operation == .move, !draggedEntries.isEmpty { reload() }
    }

    /// Drop target folder: the folder row under the pointer, or this pane's folder.
    private func dropFolder(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> String? {
        if operation == .on, row >= 0, row < entries.count, entries[row].isDirectory { return entries[row].path }
        return nil
    }

    private func sourcePane(_ info: NSDraggingInfo) -> (PaneViewController, [FileEntry])? {
        guard let data = info.draggingPasteboard.data(forType: .shellpaneEntries),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (obj["pane"] as? String).flatMap(UUID.init(uuidString:)),
              let pane = delegate?.pane(withID: id) else { return nil }
        return (pane, pane.draggedEntries)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let folder = dropFolder(info, row: row, operation: dropOperation)
        if folder == nil && showsTag { return [] }   // a tag view has no folder: only onto a folder row in it
        if folder == nil { tableView.setDropRow(-1, dropOperation: .on) }  // whole pane = this folder
        let target = folder ?? location.path
        if let (source, dragged) = sourcePane(info) {
            // Dropping onto the folder it came from, or a folder onto itself, does nothing.
            if dragged.allSatisfy({ RemotePath.parent($0.path) == target }) && source.location.ops.identity == location.ops.identity { return [] }
            if dragged.contains(where: { $0.path == target }) { return [] }
            let sameFS = source.location.ops.identity == location.ops.identity
            return sameFS && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
        }
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = location.with(path: dropFolder(info, row: row, operation: dropOperation) ?? location.path)
        if let (source, dragged) = sourcePane(info), !dragged.isEmpty {
            let sameFS = source.location.ops.identity == location.ops.identity
            let mode: TransferBatch.Mode = sameFS && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
            startTransfer(mode, dragged, from: source.location, into: target)
            return true
        }
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            startTransfer(.copy, Self.localEntries(urls), from: .local("/"), into: target)
            return true
        }
        return false
    }
}
