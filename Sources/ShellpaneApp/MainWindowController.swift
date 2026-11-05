import AppKit
import UniformTypeIdentifiers
import ShellpaneCore
import ShellpaneUI
import TransferKit
import SFTPKit
import SSHProcess
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, PaneDelegate, NSWindowDelegate {
    let sidebarModel = SidebarModel()
    let inspectorModel = InspectorModel()
    private var inspectorItem: NSSplitViewItem?
    /// Holds the panes. See PaneManagement.swift.
    let area = PaneAreaController()
    var areaItem: NSSplitViewItem?
    var layout: PaneLayout?
    var paneByID: [UUID: PaneViewController] = [:]
    /// The panes in reading order: left to right, top to bottom.
    var panes: [PaneViewController] { layout?.paneIDs.compactMap { paneByID[$0] } ?? [] }
    /// The pane F5, ⌘V and the toolbar act on. nil only with no panes open.
    var activePane: PaneViewController?
    var drag: PaneDrag?
    var picker: TransferPicker?
    /// Driven by a script (self-test, snapshot, demo): always two panes, and nothing saved or restored.
    let isScripted: Bool
    /// For scripts, which start with two panes.
    var left: PaneViewController { panes[0] }
    var right: PaneViewController { panes[1] }
    private let activityPopover = NSPopover()

    private enum Item {
        static let connect = NSToolbarItem.Identifier("connect")
        static let copy = NSToolbarItem.Identifier("copy")
        static let activity = NSToolbarItem.Identifier("activity")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let hidden = NSToolbarItem.Identifier("hidden")
        static let history = NSToolbarItem.Identifier("history")
        static let sync = NSToolbarItem.Identifier("sync")
        static let terminal = NSToolbarItem.Identifier("terminal")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let inspector = NSToolbarItem.Identifier("inspector")
        static let addPane = NSToolbarItem.Identifier("addPane")
    }

    init(scripted: Bool = false) {
        isScripted = scripted
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: Tokens.Size.windowMinWidth, height: Tokens.Size.windowMinHeight)
        window.title = "Shellpane"
        window.setFrameAutosaveName("ShellpaneMain")
        super.init(window: window)
        window.delegate = self

        let split = NSSplitViewController()
        let sidebarVC = NSHostingController(rootView: SidebarView(model: sidebarModel))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = Tokens.Size.sidebarMin
        sidebarItem.maximumThickness = Tokens.Size.sidebarMax
        split.addSplitViewItem(sidebarItem)
        let areaItem = NSSplitViewItem(viewController: area)
        areaItem.minimumThickness = Tokens.Size.paneMinWidth
        split.addSplitViewItem(areaItem)
        self.areaItem = areaItem
        inspectorModel.onChanged = { [weak self] loc in self?.folderChanged(loc.path, identity: loc.ops.identity) }
        ConnectionManager.shared.log.onRecord = { [weak self] in
            Task { @MainActor in if self?.inspectorModel.tab == .log { self?.inspectorModel.reloadLog() } }
        }
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: NSHostingController(rootView: InspectorView(model: inspectorModel)))
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 420
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 720))

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        TransferCenter.shared.window = window
        RemoteEditManager.shared.onStatus = { [weak self] message in self?.activePane?.flash(message) }
        RemoteEditManager.shared.onUploaded = { [weak self] folder, identity in self?.folderChanged(folder, identity: identity) }
        activityPopover.behavior = .transient
        activityPopover.contentViewController = NSHostingController(rootView: ActivityView(center: TransferCenter.shared))
        // Its real size, up front: left to SwiftUI, it opens smaller, is placed on screen at that size, then grows
        // off the edge (in full screen, or with the window against the screen's edge).
        activityPopover.contentSize = ActivityView.size

        sidebarModel.sshHosts = ConnectionManager.shared.sshConfigHosts
        sidebarModel.reloadFavorites()
        sidebarModel.onOpenFavorite = { [weak self] fav in self?.connect(fav) }
        sidebarModel.onEditFavorite = { [weak self] fav in self?.showServerForm(.edit(fav)) }
        sidebarModel.onDeleteFavorite = { [weak self] fav in self?.confirmDelete(fav) }
        sidebarModel.onDisconnect = { [weak self] fav in self?.disconnect(fav) }
        sidebarModel.onOpenHost = { [weak self] host in
            self?.connect(to: SSHTarget(host: host), key: "alias:" + host)
        }
        sidebarModel.onSaveHost = { [weak self] host in
            guard let self else { return }
            self.showServerForm(.connect, prefillAlias: host)
            // A look chosen for the host comes along when it's saved as a server.
            let key = AppearanceKey.host(host)
            if let icon = self.sidebarModel.appearances[key]?.icon { self.formModel?.icon = icon }
            if let colour = self.sidebarModel.ownColour(key) { self.formModel?.colour = colour }
        }
        sidebarModel.onOpenPlace = { [weak self] place in
            guard let self else { return }
            self.ensureActivePane().navigate(to: .local(place.path))
        }
        sidebarModel.onAddServer = { [weak self] in self?.showConnectPrompt() }
        sidebarModel.onOpenSynclet = { [weak self] s in self?.openSynclet(s) }
        sidebarModel.onRecolourFavorite = { [weak self] fav, colour in
            var changed = fav
            changed.colour = colour.rawValue
            try? ConnectionManager.shared.favorites.save(changed)
            self?.sidebarModel.reloadFavorites()
            self?.panes.forEach { $0.refreshChrome() }
        }
        sidebarModel.onMoveFavorite = { [weak self] fav, group in
            try? ConnectionManager.shared.groups.move(favorite: fav.id, to: group)
            self?.sidebarModel.reloadFavorites()
        }
        sidebarModel.onNewGroup = { [weak self] fav in
            self?.askGroupName(title: "New Group", initial: "") { name in
                guard let g = try? ConnectionManager.shared.groups.create(name) else { return }
                if let fav { try? ConnectionManager.shared.groups.move(favorite: fav.id, to: g.id) }
                self?.sidebarModel.reloadFavorites()
            }
        }
        sidebarModel.onRenameGroup = { [weak self] g in
            self?.askGroupName(title: "Rename Group", initial: g.name) { name in
                try? ConnectionManager.shared.groups.rename(g.id, to: name)
                self?.sidebarModel.reloadFavorites()
            }
        }
        sidebarModel.onDeleteGroup = { [weak self] g in
            try? ConnectionManager.shared.groups.delete(g.id)  // its servers stay, ungrouped
            try? ConnectionManager.shared.appearances.remove(AppearanceKey.group(g.id))
            self?.sidebarModel.reloadAppearances()
            self?.sidebarModel.reloadFavorites()
        }
        sidebarModel.onDeleteSynclet = { [weak self] s in
            try? ConnectionManager.shared.synclets.delete(id: s.id)
            try? ConnectionManager.shared.appearances.remove(AppearanceKey.synclet(s.id))
            self?.sidebarModel.reloadAppearances()
            self?.sidebarModel.reloadSynclets()
        }
        sidebarModel.reloadSynclets()
        sidebarModel.reloadBookmarks()
        sidebarModel.reloadMac()
        sidebarModel.onOpenTag = { [weak self] t in self?.ensureActivePane().showTag(t) }
        // Finder's Favorites and tags can change while Shellpane is open: read them again on coming back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarModel.reloadMac() }
        }
        sidebarModel.onOpenBookmark = { [weak self] b in self?.openBookmark(b) }
        sidebarModel.reloadAppearances()
        sidebarModel.onEditAppearance = { [weak self] item in self?.showAppearanceForm(item) }
        sidebarModel.onEditBookmark = { [weak self] b in self?.showBookmarkForm(b) }
        sidebarModel.onDeleteBookmark = { [weak self] b in
            try? ConnectionManager.shared.bookmarks.delete(b.id)   // only the shortcut: the folder itself is untouched
            self?.bookmarksChanged()
        }

        area.setStartPage(AnyView(StartPage(model: sidebarModel)))
        if scripted {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let first = makePane(location: .local(home))
            let second = makePane(location: .local(home + "/Downloads"))
            setLayout(PaneLayout.Preset.sideBySide.layout([first.paneID, second.paneID]), focus: second)
        } else {
            restorePanes()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The active pane, or a new one if there are none: what opening something from the sidebar lands in.
    /// New, it shows the start page until something opens, so a failed connection goes back there.
    @discardableResult
    func ensureActivePane() -> PaneViewController {
        if let activePane { return activePane }
        if let last = panes.last {
            paneDidBecomeActive(last)
            return last
        }
        let pane = makePane(showsStart: true)
        setLayout(.pane(pane.paneID), focus: pane)
        return pane
    }

    // MARK: - PaneDelegate

    func paneDidBecomeActive(_ pane: PaneViewController) {
        activePane = pane
        for p in panes { p.isActive = p === pane }
        updateHistoryButtons()
        paneSelectionChanged(pane)
    }

    func paneSelectionChanged(_ pane: PaneViewController) {
        guard pane === activePane, inspectorItem?.isCollapsed == false else { return }
        inspectorModel.update(location: pane.location, selection: pane.selectedEntries)
    }

    @objc func toggleInspector(_ sender: Any?) {
        guard let item = inspectorItem else { return }
        item.animator().isCollapsed.toggle()
        if !item.isCollapsed, let activePane {
            inspectorModel.update(location: activePane.location, selection: activePane.selectedEntries)
            if inspectorModel.tab == .log { inspectorModel.reloadLog() }
        }
    }

    var isInspectorShown: Bool { inspectorItem?.isCollapsed == false }

    func paneDidNavigate(_ pane: PaneViewController) {
        if pane === activePane { updateHistoryButtons() }
        updateKeyLoop()
    }

    @objc private func viewModeClicked(_ sender: NSToolbarItemGroup) {
        activePane?.viewMode = [.list, .icons, .columns][max(0, min(2, sender.selectedIndex))]
    }

    @objc func viewAsList(_ sender: Any?) { activePane?.viewMode = .list }
    @objc func viewAsColumns(_ sender: Any?) { activePane?.viewMode = .columns }
    @objc func viewAsIcons(_ sender: Any?) { activePane?.viewMode = .icons }

    func updateHistoryButtons() {
        if let mode = window?.toolbar?.items.first(where: { $0.itemIdentifier == Item.viewMode }) as? NSToolbarItemGroup {
            mode.selectedIndex = [PaneViewController.ViewMode.list, .icons, .columns].firstIndex(of: activePane?.viewMode ?? .list) ?? 0
        }
        guard let group = window?.toolbar?.items.first(where: { $0.itemIdentifier == Item.history }) as? NSToolbarItemGroup,
              group.subitems.count == 2 else { return }
        group.subitems[0].isEnabled = activePane?.canGoBack ?? false
        group.subitems[1].isEnabled = activePane?.canGoForward ?? false
    }

    @objc func goBack(_ sender: Any?) { activePane?.goBack() }
    @objc func goForward(_ sender: Any?) { activePane?.goForward() }

    @objc private func historyClicked(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { activePane?.goBack() } else { activePane?.goForward() }
    }

    func paneRequestsCopyToOtherPane(_ pane: PaneViewController) {
        activePane = pane
        copyToOtherPane(nil)
    }

    func paneRequestsReconnect(_ pane: PaneViewController) {
        activePane = pane
        pane.reconnectNow()
    }

    func paneRequestsMoveToOtherPane(_ pane: PaneViewController) {
        activePane = pane
        transferToOtherPane(.move)
    }

    func pane(withID id: UUID) -> PaneViewController? {
        paneByID[id]
    }

    // MARK: - Server appearance

    func appearance(of session: RemoteSession, openedAs: String?) -> (icon: String?, colour: ConnectionColour) {
        let fav = sidebarModel.favorites.first { $0.id == openedAs }
            ?? sidebarModel.favorites.first { $0.id == session.key }
            ?? sidebarModel.favorites.first { $0.target == session.target }
        guard let fav else {
            // A ~/.ssh/config host keeps the look chosen for it in the sidebar.
            let key = openedAs ?? session.key
            guard key.hasPrefix("alias:") else { return (nil, session.colour) }
            let look = AppearanceKey.host(String(key.dropFirst("alias:".count)))
            return (sidebarModel.appearances[look]?.icon, sidebarModel.ownColour(look) ?? session.colour)
        }
        return (fav.icon, fav.colour.flatMap(ConnectionColour.init(rawValue:)) ?? session.colour)
    }

    // MARK: - Favorite Folders

    /// Where a pane is, as a favorite folder's place: what its connection reaches, not how it was opened
    /// (a server opened twice shares one connection). nil only when that can't be found again after quitting.
    func bookmarkPlace(for location: Location) -> Bookmark.Place? {
        guard let session = location.session else { return .local }
        let key = session.key
        if key.hasPrefix("alias:") { return .sshAlias(String(key.dropFirst("alias:".count))) }
        if !key.hasPrefix("adhoc:") { return .favorite(key) }
        // Typed into Connect and not saved: the same server saved as a favorite, or a plain `ssh host`
        // with no user, port or key of its own, can be reached again. Anything else would lose a setting.
        if let fav = ConnectionManager.shared.favorites(matching: session.target).first { return .favorite(fav.id) }
        let t = session.target
        if t.user == nil, t.port == nil, t.identityFile == nil { return .sshAlias(t.host) }
        return nil
    }

    func pane(_ pane: PaneViewController, isBookmarked path: String) -> Bool {
        guard let place = bookmarkPlace(for: pane.location) else { return false }
        return sidebarModel.bookmarks.contains { $0.place == place && $0.path == path }
    }

    func pane(_ pane: PaneViewController, setBookmarked on: Bool, path: String) {
        guard let place = bookmarkPlace(for: pane.location) else {
            pane.flash("Save this server first (Add Server…): its user, port or key would be lost otherwise.")
            return
        }
        let store = ConnectionManager.shared.bookmarks
        if on {
            guard let b = try? store.add(place: place, path: path) else { return }
            pane.flash("Added “\(b.name)” to Favorite Folders.")
        } else if let b = try? store.find(place: place, path: path) {
            try? store.delete(b.id)
            pane.flash("Removed “\(b.name)” from Favorite Folders.")
        }
        bookmarksChanged()
    }

    func bookmarksChanged() {
        sidebarModel.reloadBookmarks()
        sidebarModel.reloadAppearances()
        panes.forEach { $0.refreshChrome() }
    }

    /// Opens a favorite folder in the active pane, connecting first when it's on a server not open there.
    func openBookmark(_ b: Bookmark) {
        let pane = ensureActivePane()
        switch b.place {
        case .local:
            pane.navigate(to: .local(b.path))
        case let .favorite(id):
            if pane.location.session?.key == id { pane.navigate(to: pane.location.with(path: b.path)); return }
            guard let fav = sidebarModel.favorites.first(where: { $0.id == id }) else { return }
            connect(fav, path: b.path)
        case let .sshAlias(alias):
            let key = "alias:" + alias
            if pane.location.session?.key == key { pane.navigate(to: pane.location.with(path: b.path)); return }
            connect(to: SSHTarget(host: alias), key: key, path: b.path)
        }
    }

    @objc func goToPath(_ sender: Any?) { activePane?.beginEditingPath() }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let active = activePane else { return }
        pane(active, setBookmarked: !pane(active, isBookmarked: active.location.path), path: active.location.path)
    }

    /// The sheet that edits a favorite folder's name, icon and colour.
    func showBookmarkForm(_ b: Bookmark) {
        let model = AppearanceFormModel(title: "Edit Favorite Folder", subtitle: b.path, name: b.name, icon: b.icon, colour: b.colour,
                                        standardIcon: FolderIcons.standard(for: b.place), icons: FolderIcons.all,
                                        automaticColour: sidebarModel.automaticColour(b),
                                        automaticHelp: b.place == .local ? "Automatic: no colour" : "Automatic: its server's colour",
                                        footer: "How it looks in the sidebar and on the start page.")
        present(model) { [weak model] in
            guard let model else { return }
            try ConnectionManager.shared.bookmarks.update(b.id, name: model.name, icon: model.storedIcon, colour: model.storedColour)
        }
    }

    /// The same sheet for anything else in the sidebar: just its look.
    func showAppearanceForm(_ item: AppearanceItem) {
        let saved = sidebarModel.appearances[item.key]
        let model = AppearanceFormModel(title: "Edit Appearance", subtitle: item.subtitle.isEmpty ? item.title : "\(item.title): \(item.subtitle)",
                                        icon: saved?.icon, colour: saved?.colour, standardIcon: item.standardIcon, icons: item.icons,
                                        automaticHelp: item.automaticHelp, footer: item.footer)
        present(model) { [weak model] in
            guard let model else { return }
            try ConnectionManager.shared.appearances.set(item.key, Appearance(icon: model.storedIcon, colour: model.storedColour))
        }
    }

    private func present(_ model: AppearanceFormModel, save: @escaping () throws -> Void) {
        guard let window, appearanceSheet == nil else { return }
        appearanceFormModel = model
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: AppearanceFormView(model: model)))
        appearanceSheet = sheet
        let close = { [weak self, weak window] in
            if let sheet = self?.appearanceSheet { window?.endSheet(sheet) }
            self?.appearanceSheet = nil
            self?.appearanceFormModel = nil
        }
        model.onCancel = close
        model.onSave = { [weak self] in
            guard let self else { return }
            do {
                try save()
            } catch {
                self.showProblemOn(sheet, title: "Couldn't save it", message: error.localizedDescription)
                return
            }
            close()
            self.bookmarksChanged()
        }
        window.beginSheet(sheet)
    }

    func folderChanged(_ folder: String, identity: String) {
        for pane in panes where pane.location.ops.identity == identity && pane.location.path == folder {
            pane.reload()
        }
    }

    // MARK: - Actions

    @objc func showConnectPrompt(_ sender: Any? = nil) {
        showServerForm(.connect)
    }

    private(set) var formSheet: NSWindow?
    private var appearanceSheet: NSWindow?
    /// The open appearance sheet's model (the self-test fills it in).
    private(set) var appearanceFormModel: AppearanceFormModel?
    /// The open server form's model (the self-test and the video's state capture fill it in).
    private(set) var formModel: ServerFormModel?

    /// S03 (connect) and S05 (edit) as a sheet on the main window.
    func showServerForm(_ mode: ServerFormModel.Mode, prefillAlias: String? = nil) {
        guard let window, formSheet == nil else { return }
        let model = ServerFormModel(mode: mode, configHosts: ConnectionManager.shared.sshConfigHosts, prefillAlias: prefillAlias)
        formModel = model
        let host = NSHostingController(rootView: ServerFormView(model: model))
        let sheet = NSWindow(contentViewController: host)
        formSheet = sheet
        let close = { [weak self, weak window] in
            if let sheet = self?.formSheet { window?.endSheet(sheet) }
            self?.formSheet = nil
            self?.formModel = nil
        }
        model.onCancel = close
        model.onDelete = { [weak self] fav in
            close()
            self?.confirmDelete(fav)
        }
        model.onSubmit = { [weak self] fav, password, savePassword, saveAsFavorite in
            guard let self else { return }
            if saveAsFavorite {
                do {
                    try ConnectionManager.shared.save(fav)
                } catch {
                    model.errors = [(error as? Favorite.ValidationError) ?? .missingServer]
                    self.showError(title: "Couldn't save the server", message: error.localizedDescription)
                    return
                }
                self.sidebarModel.reloadFavorites()
            }
            close()
            if case .connect = mode {
                self.connect(fav, typedPassword: password, savePassword: savePassword, saved: saveAsFavorite)
            }
        }
        window.beginSheet(sheet)
    }

    private func askGroupName(title: String, initial: String, done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Groups keep the sidebar tidy. Deleting a group keeps its servers."
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = "Clients"
        alert.accessoryView = field
        alert.addButton(withTitle: initial.isEmpty ? "Create" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if response == .alertFirstButtonReturn, !name.isEmpty { done(name) }
        }
    }

    // MARK: - Export / import

    @objc func exportServers(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Shellpane servers.json"
        panel.message = "Servers, groups and saved syncs. Passwords stay in this Mac's Keychain and aren't included."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let cm = ConnectionManager.shared
                try BackupIO.export(favorites: cm.favorites, groups: cm.groups, synclets: cm.synclets).write(to: url, options: .atomic)
                self?.activePane?.flash("Exported servers to \(url.lastPathComponent).")
            } catch {
                self?.showError(title: "Couldn't export", message: error.localizedDescription)
            }
        }
    }

    @objc func importServers(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a file exported from Shellpane."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let cm = ConnectionManager.shared
                let r = try BackupIO.importBackup(try Data(contentsOf: url), favorites: cm.favorites, groups: cm.groups, synclets: cm.synclets)
                self.sidebarModel.reloadFavorites()
                self.sidebarModel.reloadSynclets()
                self.showError(title: "Imported", message: "\(r.servers) server\(r.servers == 1 ? "" : "s"), \(r.groups) group\(r.groups == 1 ? "" : "s"), \(r.syncs) saved sync\(r.syncs == 1 ? "" : "s")"
                               + (r.skipped > 0 ? ". \(r.skipped) already here, skipped." : ".") + " Shellpane asks for each server's password the first time you connect.")
            } catch {
                self.showError(title: "That isn't a Shellpane export", message: error.localizedDescription)
            }
        }
    }

    @objc func toggleFilter(_ sender: Any?) { activePane?.toggleFilter() }

    // MARK: - Sync (S10)

    private var syncSheet: NSWindow?

    @objc func openInTerminal(_ sender: Any?) { activePane?.openInTerminal() }

    @objc func newTab(_ sender: Any?) { activePane?.newTab() }
    /// ⌘W: the active pane's tab if it has more than one, otherwise the pane; with no panes, the window.
    @objc func closeTabOrWindow(_ sender: Any?) {
        guard let activePane else { window?.performClose(sender); return }
        if !activePane.closeTab() { closePane(activePane) }
    }
    @objc func nextTab(_ sender: Any?) { activePane?.nextTab(1) }
    @objc func previousTab(_ sender: Any?) { activePane?.nextTab(-1) }

    /// The active pane against another one. Two panes: those two, in reading order. More: pick which.
    @objc func showSync(_ sender: Any?) {
        guard let active = activePane else { NSSound.beep(); return }
        let others = panes.filter { $0 !== active }
        guard !others.isEmpty else {
            NSSound.beep()
            active.flash("Open a second pane to compare two folders (⌘\\).")
            return
        }
        guard active.acceptsNewItems() else { return }
        if others.count == 1 {
            guard others[0].acceptsNewItems() else { return }
            let ordered = panes
            presentSync(SyncModel(left: ordered[0].location, right: ordered[1].location))
            return
        }
        showPicker(source: active, sourceText: "Comparing this folder", actionText: "Compare with this folder",
                   problem: { pane in
                       if pane.showsStart { return "No folder open here yet" }
                       if pane.showsTag { return "Showing a tag, not a folder" }
                       return nil
                   },
                   openPane: nil) { [weak self, weak active] other in
            guard let self, let active else { return }
            let ordered = self.panes.filter { $0 === active || $0 === other }
            guard ordered.count == 2 else { return }
            self.presentSync(SyncModel(left: ordered[0].location, right: ordered[1].location))
        }
    }

    @objc func splitRight(_ sender: Any?) { split(.right) }
    @objc func splitDown(_ sender: Any?) { split(.bottom) }
    @objc func closeActivePane(_ sender: Any?) {
        if let activePane { closePane(activePane) } else { NSSound.beep() }
    }

    func presentSync(_ model: SyncModel) {
        guard let window, syncSheet == nil else { return }
        let host = NSHostingController(rootView: SyncView(model: model, onSave: { [weak self, weak model] in
            guard let self, let model else { return }
            self.saveSynclet(model)
        }))
        let sheet = NSWindow(contentViewController: host)
        sheet.setContentSize(NSSize(width: 900, height: 620))
        syncSheet = sheet
        model.onClose = { [weak self, weak window] in
            if let sheet = self?.syncSheet { window?.endSheet(sheet) }
            self?.syncSheet = nil
        }
        model.onSynced = { [weak self] in
            self?.panes.forEach { $0.reload() }
        }
        window.beginSheet(sheet)
        model.compare()
    }

    private func saveSynclet(_ model: SyncModel) {
        guard let sheet = syncSheet else { return }
        if let problem = model.saveProblem {
            showProblemOn(sheet, title: "Can't save this sync yet", message: problem)
            return
        }
        let alert = NSAlert()
        alert.messageText = model.syncletName == nil ? "Save as Synclet" : "Update Synclet"
        alert.informativeText = "It appears under Synclets in the sidebar, with these folders and options."
        let field = NSTextField(string: model.syncletName ?? "\(model.left.displayName) ↔ \(model.right.displayName)")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            do {
                try model.saveSynclet(name: name)
                self.sidebarModel.reloadSynclets()
            } catch {
                self.showProblemOn(sheet, title: "Couldn't save the synclet", message: error.localizedDescription)
            }
        }
    }

    private func showProblemOn(_ window: NSWindow, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    /// Reconnects whatever servers the synclet needs, then opens it.
    func openSynclet(_ s: Synclet) {
        Task { @MainActor in
            do {
                let l = try await location(favoriteID: s.leftFavoriteID, path: s.leftPath)
                let r = try await location(favoriteID: s.rightFavoriteID, path: s.rightPath)
                presentSync(SyncModel(left: l, right: r, synclet: s))
            } catch {
                showError(title: "Couldn't open “\(s.name)”", message: error.localizedDescription)
            }
        }
    }

    private func location(favoriteID: String?, path: String) async throws -> Location {
        guard let id = favoriteID else { return .local(path) }
        guard let fav = try ConnectionManager.shared.favorites.favorite(id: id) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Its server was deleted."])
        }
        let session = try await ConnectionManager.shared.connect(fav)
        sidebarModel.connected[fav.id] = session.colour
        return .remote(session, path)
    }

    func confirmDelete(_ fav: Favorite) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(fav.name)”?"
        alert.informativeText = "Shellpane forgets this server and removes its saved password from Keychain. Nothing on the server is touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try ConnectionManager.shared.delete(fav)
            } catch {
                self.showError(title: "Couldn't delete the server", message: error.localizedDescription)
            }
            self.sidebarModel.connected[fav.id] = nil
            self.sidebarModel.reloadFavorites()
            self.bookmarksChanged()   // a deleted server's favorite folders go with it
        }
    }

    func disconnect(_ fav: Favorite) {
        ConnectionManager.shared.disconnect(fav.id)
        sidebarModel.connected[fav.id] = nil
        for pane in panes where pane.location.session?.isAlive == false {
            pane.navigate(to: .local(FileManager.default.homeDirectoryForCurrentUser.path))
        }
    }

    /// A saved server (or one just typed into the form, `saved: false`).
    func connect(_ fav: Favorite, typedPassword: String? = nil, savePassword: Bool = false, saved: Bool = true,
                 path: String? = nil) {
        let key = saved ? fav.id : "adhoc:" + fav.id
        run(key: key, label: fav.name, pane: ensureActivePane(), path: path ?? fav.initialPath) {
            try await ConnectionManager.shared.connect(fav, typedPassword: typedPassword, savePassword: savePassword && saved)
        }
    }

    /// An ssh_config alias or a typed address, not saved.
    func connect(to target: SSHTarget, key: String, path: String? = nil) {
        run(key: key, label: target.displayName, pane: ensureActivePane(), path: path) {
            try await ConnectionManager.shared.connect(target)
        }
    }

    private func run(key: String, label: String, pane: PaneViewController, path: String?,
                     _ open: @escaping @MainActor () async throws -> RemoteSession) {
        sidebarModel.failed.remove(key)
        sidebarModel.connecting.insert(key)
        // Leaving the start page for now; a failed connection comes back to it.
        let startPage = pane.showsStart, resume = pane.resume
        pane.setShowsStart(false)
        pane.showBusy("Connecting to \(label)…")
        Task { @MainActor in
            defer { sidebarModel.connecting.remove(key) }
            do {
                let session = try await open()
                sidebarModel.connected[key] = session.colour
                // BUG-004: the same server saved as a favorite is connected too.
                for fav in ConnectionManager.shared.favorites(matching: session.target) {
                    sidebarModel.connected[fav.id] = session.colour
                }
                pane.showBusy(nil)
                pane.navigate(to: .remote(session, path ?? session.home))
                pane.openedAs = key
                pane.refreshChrome()
                pane.view.window?.makeFirstResponder(pane.focusView)
                savePanes()
            } catch {
                sidebarModel.failed.insert(key)
                pane.showBusy(nil)
                if startPage {
                    pane.resume = resume
                    pane.setShowsStart(true)
                } else {
                    pane.reload()
                }
                showConnectFailure(label: label, error: error)
            }
        }
    }

    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(.copy) }

    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(.move) }

    func transferToOtherPane(_ mode: TransferBatch.Mode) { transfer(mode) }

    /// The toolbar button: always shows where the files can go.
    @objc func transferClicked(_ sender: Any?) { transfer(.copy, alwaysAsk: true) }

    @objc func showActivity(_ sender: Any?) {
        if activityPopover.isShown { activityPopover.close(); return }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Item.activity }), item.isVisible {
            activityPopover.show(relativeTo: item)
        } else if let view = window?.contentView {
            activityPopover.show(relativeTo: NSRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 10, width: 1, height: 1),
                                 of: view, preferredEdge: .minY)
        }
    }

    /// The Activity popover's window while it's open.
    var activityPopoverFrame: NSRect? {
        activityPopover.isShown ? activityPopover.contentViewController?.view.window?.frame : nil
    }

    /// Closes the transfer popover (the demo recording captures only the window).
    func hideActivity() { activityPopover.close() }

    @objc func reloadActive(_ sender: Any?) { activePane?.reload() }

    @objc func goUp(_ sender: Any?) { activePane?.goUp() }

    @objc func openSelection(_ sender: Any?) { activePane?.openSelected() }

    @objc func toggleHidden(_ sender: Any?) {
        let show = !(activePane?.showHidden ?? false)
        panes.forEach { $0.showHidden = show }
    }

    /// The plain reason, ssh's own words behind it, and a command to try the same login in Terminal.
    func showConnectFailure(label: String, error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't connect to \(label)"
        alert.informativeText = error.localizedDescription
        let failure = error as? SSHConnectError
        if let raw = failure?.failure.raw, !raw.isEmpty {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
            text.string = raw
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isEditable = false
            let scroll = NSScrollView(frame: text.frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "OK")
        if failure != nil { alert.addButton(withTitle: "Copy Test Command") }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn, let cmd = failure?.testCommand else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    func showError(title: String, message: String, details: String? = nil) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let details, !details.isEmpty {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
            text.string = details
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isEditable = false
            let scroll = NSScrollView(frame: text.frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
        }
        alert.beginSheetModal(for: window)
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Item.history, Item.viewMode, Item.connect, Item.addPane, .flexibleSpace, Item.copy, Item.sync, Item.terminal, Item.refresh, Item.hidden, Item.activity, .inspectorTrackingSeparator, Item.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Item.viewMode {
            let images = [NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
                          NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                          NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns")!]
            let group = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne,
                                           labels: ["List", "Icons", "Columns"], target: self, action: #selector(viewModeClicked(_:)))
            group.label = "View"
            group.paletteLabel = "View"
            group.toolTip = "As list (⌘1), icons (⌘2) or columns (⌘3)"
            group.selectedIndex = 0
            return group
        }
        if id == Item.history {
            let images = [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                          NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!]
            let group = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .momentary,
                                           labels: ["Back", "Forward"], target: self, action: #selector(historyClicked(_:)))
            group.label = "Back/Forward"
            group.paletteLabel = "Back/Forward"
            group.toolTip = "Back (⌘[) / Forward (⌘])"
            group.subitems.forEach { $0.isEnabled = false }
            return group
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        func set(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) {
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
        }
        switch id {
        case Item.connect: set("Connect", "plus.circle", #selector(showConnectPrompt(_:)), "Connect to a server (⌘K)")
        case Item.addPane: set("New Pane", "rectangle.split.2x1", #selector(splitRight(_:)), "Add a pane on the right (⌘\\), or below (⇧⌘\\)")
        case Item.copy: set("Transfer", "arrow.left.arrow.right", #selector(transferClicked(_:)), "Choose a pane to copy the selected files to (F5)")
        case Item.sync: set("Sync", "arrow.triangle.2.circlepath", #selector(showSync(_:)), "Compare and sync two panes' folders")
        case Item.inspector: set("Info", "info.circle", #selector(toggleInspector(_:)), "Show or hide Info and the Log (⌥⌘I)")
        case Item.terminal: set("Terminal", "terminal", #selector(openInTerminal(_:)), "Open this folder in a terminal; on a server, over ssh (⌥⌘T)")
        case Item.refresh: set("Refresh", "arrow.clockwise", #selector(reloadActive(_:)), "Reload this folder (⌘R)")
        case Item.hidden: set("Hidden Files", "eye", #selector(toggleHidden(_:)), "Show or hide hidden files (⌘⇧.)")
        case Item.activity: set("Activity", "arrow.up.arrow.down", #selector(showActivity(_:)), "Transfers")
        default: return nil
        }
        return item
    }

    func windowWillClose(_ notification: Notification) {
        savePanes()
        ConnectionManager.shared.closeAll()
    }
}
