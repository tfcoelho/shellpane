import AppKit
import ShellpaneUI
import SFTPKit
import SwiftUI
import TransferKit
import UniformTypeIdentifiers

@MainActor
protocol PaneDelegate: AnyObject {
    func paneDidBecomeActive(_ pane: PaneViewController)
    func paneRequestsCopyToOtherPane(_ pane: PaneViewController)
    func paneRequestsMoveToOtherPane(_ pane: PaneViewController)
    func paneRequestsReconnect(_ pane: PaneViewController)
    func pane(withID id: UUID) -> PaneViewController?
    /// The pane went somewhere (or its history changed): update Back/Forward and the title.
    func paneDidNavigate(_ pane: PaneViewController)
    /// Selection or contents changed: the inspector follows the active pane.
    func paneSelectionChanged(_ pane: PaneViewController)
    /// Something changed in `folder` on the filesystem `identity`: reload every pane showing it.
    func folderChanged(_ folder: String, identity: String)
    /// Favorite Folders: whether `path`, where this pane is (this Mac or its server), is one; add or remove it.
    func pane(_ pane: PaneViewController, isBookmarked path: String) -> Bool
    func pane(_ pane: PaneViewController, setBookmarked on: Bool, path: String)
    /// How a connection is shown: the saved server's icon and colour, as they are now. `openedAs` is the
    /// server this pane was opened through, since two saved servers on one host share a connection.
    func appearance(of session: RemoteSession, openedAs: String?) -> (icon: String?, colour: ConnectionColour)
}

/// Keyboard: ⌘↓ or double-click opens, ⌘↑ goes up, Return renames (as in Finder), ⌘⌫ deletes,
/// Tab switches pane, F5 copies and F6 moves to the other pane, ⌘C / ⌘V copy and paste files.
final class PaneTableView: NSTableView {
    var onOpen: () -> Void = {}
    var onUp: () -> Void = {}
    var onCopy: () -> Void = {}
    var onMove: () -> Void = {}
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    var onClipboardCopy: () -> Void = {}
    var onClipboardPaste: () -> Void = {}
    var onFocus: () -> Void = {}
    var onQuickLook: () -> Void = {}
    var onEdit: () -> Void = {}
    var onNewFolder: () -> Void = {}
    var onFilter: () -> Void = {}
    var onCursorMoved: () -> Void = {}
    /// → / ←: show or hide a folder's contents in place, as Finder's list view does.
    var onEditPath: () -> Void = {}
    var onExpand: (Int) -> Void = { _ in }
    var onCollapse: (Int) -> Void = { _ in }

    /// Commander keys (on by default; Settings): Space / Insert mark the item under the cursor
    /// and move down, ↑ ↓ move the cursor without losing marks, Esc clears them, F3–F8 act, / filters.
    static var commanderKeys: Bool {
        get { UserDefaults.standard.object(forKey: "ShellpaneCommanderKeys") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ShellpaneCommanderKeys") }
    }

    /// The row the keyboard is on. With marks, it moves independently of the selection.
    private(set) var cursor = -1 { didSet { if cursor != oldValue { refreshCursor() } } }
    /// True after Space/Insert marked something: arrows then move the cursor only.
    private(set) var marking = false { didSet { if marking != oldValue { refreshCursor() } } }

    func setCursor(_ row: Int) { cursor = row }

    private func refreshCursor() {
        enumerateAvailableRowViews { view, row in
            (view as? CursorRowView)?.isCursor = marking && row == cursor
        }
        onCursorMoved()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let commander = Self.commanderKeys
        switch event.keyCode {
        case 125 where mods == .command: onOpen()     // ⌘↓
        case 126 where mods == .command: onUp()       // ⌘↑
        case 36 where mods.isEmpty, 76 where mods.isEmpty: onRename()  // Return / Enter
        case 51 where mods == .command: onDelete()    // ⌘⌫
        case 96: onCopy()                             // F5
        case 97: onMove()                             // F6
        case 99: onQuickLook()                        // F3
        case 118: onEdit()                            // F4
        case 98: onNewFolder()                        // F7
        case 100: onDelete()                          // F8
        case 49 where mods.isEmpty:                   // Space
            if commander { toggleMarkAndAdvance() } else { onQuickLook() }
        case 114 where mods.isEmpty && commander:     // Insert (Help on Mac keyboards)
            toggleMarkAndAdvance()
        case 53 where mods.isEmpty && marking:        // Esc
            clearMarks()
        case 44 where mods.isEmpty && commander:      // "/"
            onFilter()
        case 37 where mods == .command: onEditPath()  // ⌘L: type a path
        case 124 where mods.isEmpty:                  // → shows a folder's contents in place
            onExpand(marking ? cursor : selectedRow)
        case 123 where mods.isEmpty:                  // ← hides them, or goes to the enclosing folder
            onCollapse(marking ? cursor : selectedRow)
        case 125 where mods.isEmpty && marking:       // ↓ moves the cursor, keeps the marks
            moveCursor(1)
        case 126 where mods.isEmpty && marking:       // ↑
            moveCursor(-1)
        default:
            super.keyDown(with: event)
            if !marking { cursor = selectedRow }
        }
    }

    override func mouseDown(with event: NSEvent) {
        marking = false
        super.mouseDown(with: event)
        cursor = clickedRow >= 0 ? clickedRow : selectedRow
    }

    func toggleMarkAndAdvance() {
        guard numberOfRows > 0 else { return }
        let row = cursor >= 0 && cursor < numberOfRows ? cursor : max(0, selectedRow)
        if !marking {
            // The first mark replaces a plain selection: commander marks are explicit.
            marking = true
            selectRowIndexes([row], byExtendingSelection: false)
        } else if isRowSelected(row) {
            deselectRow(row)
        } else {
            selectRowIndexes([row], byExtendingSelection: true)
        }
        cursor = min(row + 1, numberOfRows - 1)
        scrollRowToVisible(cursor)
    }

    func clearMarks() {
        let keep = cursor
        marking = false
        if keep >= 0 && keep < numberOfRows { selectRowIndexes([keep], byExtendingSelection: false) } else { deselectAll(nil) }
    }

    private func moveCursor(_ step: Int) {
        guard numberOfRows > 0 else { return }
        cursor = max(0, min(numberOfRows - 1, cursor + step))
        scrollRowToVisible(cursor)
    }

    /// After a reload the marks are gone (the selection is restored by name, but marking mode ends).
    func endMarking() { marking = false }

    @objc func copy(_ sender: Any?) { onClipboardCopy() }
    @objc func paste(_ sender: Any?) { onClipboardPaste() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus() }
        return ok
    }

    /// Stripes only behind real rows; the empty space below the last file stays plain.
    override func drawBackground(inClipRect clipRect: NSRect) {
        let colors = NSColor.alternatingContentBackgroundColors
        colors[0].setFill()
        clipRect.fill()
        guard usesAlternatingRowBackgroundColors, numberOfRows > 0 else { return }
        let visible = rows(in: clipRect)
        for row in visible.location..<min(NSMaxRange(visible), numberOfRows) where row % 2 == 1 {
            colors[1 % colors.count].setFill()
            rect(ofRow: row).intersection(clipRect).fill()
        }
    }

}

/// A list cell whose colours follow the row: our token colours normally, the system's selected-text colour
/// on a selected row, so size, date and kind stay readable on any accent, in light and dark (BUG-009).
final class PaneCellView: NSTableCellView {
    var normalText: NSColor = Tokens.NSColors.text { didSet { apply() } }
    var normalTint: NSColor = Tokens.NSColors.textMuted { didSet { apply() } }
    /// Name column only: the triangle that shows a folder's contents in place, and the indent for nested rows.
    var disclosure: NSButton?
    var indent: NSLayoutConstraint?

    override var backgroundStyle: NSView.BackgroundStyle { didSet { apply() } }

    private func apply() {
        let selected = backgroundStyle == .emphasized
        textField?.textColor = selected ? .alternateSelectedControlTextColor : normalText
        imageView?.contentTintColor = selected ? .alternateSelectedControlTextColor : normalTint
    }
}

/// Draws the commander cursor: a thin accent outline on the row the keyboard is on while marking.
final class CursorRowView: NSTableRowView {
    var isCursor = false { didSet { if isCursor != oldValue { needsDisplay = true } } }

    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isCursor else { return }
        Tokens.NSColors.accent.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: Tokens.Radius.sm, yRadius: Tokens.Radius.sm)
        path.lineWidth = 1.5
        path.stroke()
    }
}

@MainActor
final class PaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: PaneDelegate?
    let paneID = UUID()
    /// What's being dragged out of this pane right now.
    var draggedEntries: [FileEntry] = []
    /// NSFilePromiseProvider holds its delegate weakly; these live until the drag ends.
    var promiseDelegates: [RemotePromiseDelegate] = []
    private var autoReconnectTried = false
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private let activeMarker = NSView()
    /// The pane that F5, ⌘V and the toolbar act on. Shown by an accent line under its path bar.
    var isActive = false { didSet { activeMarker.isHidden = !isActive } }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    private var flashMessage: String?
    private var flashTask: Task<Void, Never>?
    private(set) var location: Location
    /// The saved server (or "alias:host") this pane was opened through; nil on this Mac.
    var openedAs: String?
    /// The rows of the list: the folder's items, with the contents of expanded folders under them.
    private(set) var entries: [FileEntry] = []
    /// How deep each row is (0 = in this folder), parallel to `entries`.
    private(set) var depths: [Int] = []
    private var allEntries: [FileEntry] = []
    /// Showing everything with this Finder tag (a click on the sidebar's tag) instead of a folder. Rows keep
    /// their own paths, so copying, renaming and deleting work; there's no folder to put things into.
    private(set) var tag: FinderTag?
    var showsTag: Bool { tag != nil }
    /// Folders shown open in place (list view), by path, with their listing.
    private(set) var expanded: [String: [FileEntry]] = [:]
    var showHidden = false {
        didSet {
            applyFilterAndSort()
            if viewMode == .columns { columns.show(location, showHidden: showHidden); columns.refresh() }
        }
    }

    let tableView = PaneTableView()
    private let scrollView = NSScrollView()
    private let pathHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let tabHost = NSHostingView(rootView: AnyView(EmptyView()))
    /// The quick filter (⌥⌘F or "/"): only names containing the text are shown.
    let filterField = NSSearchField()
    /// Typing a path (click the path bar's empty part, ⌘L, ⇧⌘G): a field laid over the path bar.
    let pathField = NSTextField()
    private var filterHeight: NSLayoutConstraint?
    private(set) var filterText = ""
    private var tabHeight: NSLayoutConstraint?

    /// A tab: where it is and its own Back/Forward. The current tab's live state is in location/backStack/forwardStack.
    struct Tab {
        var location: Location
        var back: [Location] = []
        var forward: [Location] = []
    }
    private(set) var tabs: [Tab] = []
    private(set) var currentTab = 0
    private let statusHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let overlayHost = OverlayHostingView(rootView: AnyView(EmptyView()))
    private var loadTask: Task<Void, Never>?
    private var isLoading = false
    /// True while a listing is in flight (the table may be replaced when it lands).
    var isReloading: Bool { isLoading }
    private var busyMessage: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(location: Location) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isRemote: Bool { location.session != nil }

    var selectedEntries: [FileEntry] {
        if viewMode == .columns { return columns.selectedEntries }
        if viewMode == .icons { return icons.selectedEntries }
        return tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    enum ViewMode: String { case list, icons, columns }
    let columns = ColumnController()
    let icons = IconController()
    /// ⌘1 list, ⌘2 icons, ⌘3 columns.
    var viewMode: ViewMode = .list {
        didSet {
            guard viewMode != oldValue else { return }
            applyViewMode()
        }
    }

    private func applyViewMode() {
        scrollView.isHidden = viewMode != .list
        columns.browser.isHidden = viewMode != .columns
        icons.scrollView.isHidden = viewMode != .icons
        switch viewMode {
        case .columns:
            columns.show(location, showHidden: showHidden)
            view.window?.makeFirstResponder(columns.browser)
        case .icons:
            applyFilterAndSort()   // icons show this folder's items only, without expanded contents
            view.window?.makeFirstResponder(icons.collection)
        case .list:
            applyFilterAndSort()
            view.window?.makeFirstResponder(tableView)
        }
        refreshChrome()
        delegate?.paneDidNavigate(self)
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Tokens.NSColors.bg

        activeMarker.wantsLayer = true
        activeMarker.layer?.backgroundColor = Tokens.NSColors.accent.cgColor
        activeMarker.isHidden = !isActive
        activeMarker.setAccessibilityElement(false)
        columns.browser.isHidden = true
        columns.browser.menu = tableView.menu
        columns.onSelectionChange = { [weak self] folder, _ in
            guard let self else { return }
            // Clicking through columns moves "where this pane is" without reloading anything.
            if folder != self.location.path { self.location = self.location.with(path: folder) }
            self.refreshChrome()
        }
        columns.onOpenFile = { [weak self] entry in
            guard let self else { return }
            if case .local = self.location { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) } else { self.editRemote(entry, with: nil) }
        }
        icons.scrollView.isHidden = true
        icons.collection.pane = self
        icons.collection.menu = tableView.menu
        icons.onSelectionChange = { [weak self] in self?.refreshChrome() }
        filterField.placeholderString = "Filter by name"
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.delegate = self
        filterField.isHidden = true
        filterField.setAccessibilityLabel("Filter files by name")
        pathField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        pathField.bezelStyle = .roundedBezel
        pathField.lineBreakMode = .byTruncatingHead
        pathField.isHidden = true
        pathField.delegate = self
        pathField.placeholderString = "Type a path: /var/www, ~/logs, .."
        pathField.setAccessibilityLabel("Go to path")
        for v in [tabHost, pathHost, scrollView, columns.browser, icons.scrollView, statusHost, overlayHost, activeMarker, filterField, pathField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabHost.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),  // below the unified toolbar
            tabHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathHost.topAnchor.constraint(equalTo: tabHost.bottomAnchor),
            pathHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathHost.heightAnchor.constraint(equalToConstant: Tokens.Size.pathBar),

            activeMarker.bottomAnchor.constraint(equalTo: pathHost.bottomAnchor),
            activeMarker.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            activeMarker.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            activeMarker.heightAnchor.constraint(equalToConstant: Tokens.Size.activePaneMarker),

            pathField.leadingAnchor.constraint(equalTo: pathHost.leadingAnchor, constant: Tokens.Space.s6),
            // Stops short of the ☆ and copy buttons, which stay usable while typing.
            pathField.trailingAnchor.constraint(equalTo: pathHost.trailingAnchor, constant: -56),
            pathField.centerYAnchor.constraint(equalTo: pathHost.centerYAnchor),
            filterField.topAnchor.constraint(equalTo: pathHost.bottomAnchor, constant: Tokens.Space.s2),
            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Tokens.Space.s8),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Tokens.Space.s8),
            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: Tokens.Space.s2),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusHost.topAnchor),

            icons.scrollView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            icons.scrollView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            icons.scrollView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            icons.scrollView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            columns.browser.topAnchor.constraint(equalTo: scrollView.topAnchor),
            columns.browser.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            columns.browser.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            columns.browser.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            statusHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusHost.heightAnchor.constraint(equalToConstant: Tokens.Size.statusBar),

            overlayHost.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            overlayHost.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            overlayHost.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: Tokens.Size.paneMinWidth),
        ])
        let fh = filterField.heightAnchor.constraint(equalToConstant: 0)
        fh.isActive = true
        filterHeight = fh
        let th = tabHost.heightAnchor.constraint(equalToConstant: 0)  // hidden until there's a second tab
        th.isActive = true
        tabHeight = th
        view = root
        tabs = [Tab(location: location)]
        refreshChrome()
        reload()
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat, String)] = [
            ("name", "Name", 220, "name"),
            ("size", "Size", 72, "size"),
            ("date", "Date Modified", 128, "date"),
            ("kind", "Kind", 100, "kind"),
        ]
        for (id, title, width, key) in columns {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = id == "name" ? 120 : 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            if id == "size" { c.headerCell.alignment = .right }
            tableView.addTableColumn(c)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        tableView.style = .fullWidth
        tableView.rowHeight = Tokens.Size.rowMedium
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.setAccessibilityLabel("Files")
        tableView.onOpen = { [weak self] in self?.openSelected() }
        tableView.onUp = { [weak self] in self?.goUp() }
        tableView.onEditPath = { [weak self] in self?.beginEditingPath() }
        tableView.onExpand = { [weak self] row in self?.setExpanded(true, row: row) }
        tableView.onCollapse = { [weak self] row in self?.collapseOrGoToParent(row: row) }
        tableView.onCopy = { [weak self] in self.map { $0.delegate?.paneRequestsCopyToOtherPane($0) } }
        tableView.onMove = { [weak self] in self.map { $0.delegate?.paneRequestsMoveToOtherPane($0) } }
        tableView.onRename = { [weak self] in self?.renameSelected() }
        tableView.onDelete = { [weak self] in self?.deleteSelected() }
        tableView.onClipboardCopy = { [weak self] in self?.copyToClipboard() }
        tableView.onClipboardPaste = { [weak self] in self?.pasteFromClipboard() }
        tableView.onQuickLook = { [weak self] in self?.quickLook() }
        tableView.onEdit = { [weak self] in self?.editSelected() }
        tableView.onNewFolder = { [weak self] in self?.newFolder(nil) }
        tableView.onFilter = { [weak self] in self?.showFilter() }
        tableView.onCursorMoved = { [weak self] in self?.refreshChrome() }
        configureDragAndDrop()
        configureMenu()
        tableView.onFocus = { [weak self] in self.map { $0.delegate?.paneDidBecomeActive($0) } }
    }

    // MARK: - Navigation

    /// Goes somewhere. Records history unless it's a Back/Forward step itself.
    func navigate(to newLocation: Location, recordHistory: Bool = true) {
        tag = nil
        if newLocation.session == nil { openedAs = nil }
        if recordHistory, !Self.same(location, newLocation) {
            backStack.append(location)
            if backStack.count > 100 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        location = newLocation
        if !filterText.isEmpty || !filterField.isHidden {
            filterText = ""
            filterField.stringValue = ""
            filterField.isHidden = true
            filterHeight?.isActive = true
        }
        allEntries = []
        entries = []
        depths = []
        expanded = [:]
        tableView.reloadData()
        refreshChrome()
        reload()
        if viewMode == .columns { columns.show(newLocation, showHidden: showHidden) }
        delegate?.paneDidNavigate(self)
    }

    // MARK: - Quick filter

    @objc func toggleFilter() {
        if filterField.isHidden { showFilter() } else { clearFilter() }
    }

    func showFilter() {
        filterField.isHidden = false
        filterHeight?.isActive = false
        view.window?.makeFirstResponder(filterField)
    }

    func clearFilter() {
        filterField.stringValue = ""
        filterText = ""
        filterField.isHidden = true
        filterHeight?.isActive = true
        applyFilterAndSort()
        view.window?.makeFirstResponder(tableView)
    }

    func setFilter(_ text: String) {
        filterText = text
        applyFilterAndSort()
        if !entries.isEmpty, tableView.selectedRowIndexes.isEmpty { tableView.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func filterChanged() { setFilter(filterField.stringValue) }

    // MARK: - Tabs

    private func saveCurrentTab() {
        guard tabs.indices.contains(currentTab) else { return }
        tabs[currentTab] = Tab(location: location, back: backStack, forward: forwardStack)
    }

    /// ⌘T: a new tab next to this one, at the same folder.
    @objc func newTab() {
        saveCurrentTab()
        tabs.insert(Tab(location: location), at: currentTab + 1)
        selectTab(currentTab + 1, save: false)
    }

    func selectTab(_ index: Int, save: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        if save { saveCurrentTab() }
        currentTab = index
        let tab = tabs[index]
        backStack = tab.back
        forwardStack = tab.forward
        navigate(to: tab.location, recordHistory: false)
    }

    /// ⌘W: closes this tab. Returns false when it's the last one (the window closes instead).
    @discardableResult
    func closeTab(_ index: Int? = nil) -> Bool {
        let i = index ?? currentTab
        guard tabs.count > 1, tabs.indices.contains(i) else { return false }
        saveCurrentTab()
        tabs.remove(at: i)
        let next = i < currentTab ? currentTab - 1 : min(currentTab, tabs.count - 1)
        currentTab = -1
        selectTab(next, save: false)
        return true
    }

    func nextTab(_ step: Int) {
        guard tabs.count > 1 else { NSSound.beep(); return }
        selectTab((currentTab + step + tabs.count) % tabs.count)
    }

    private func refreshTabs() {
        saveCurrentTab()
        let shown = tabs.count > 1
        tabHeight?.constant = shown ? Tokens.Size.tabBar : 0
        tabHost.isHidden = !shown
        guard shown else { return }
        let items = tabs.enumerated().map { i, t in
            TabStrip.Item(index: i, title: t.location.displayTitle, remote: t.location.session.map { $0.colour }, isCurrent: i == currentTab)
        }
        tabHost.rootView = AnyView(TabStrip(items: items,
                                            onSelect: { [weak self] i in self?.selectTab(i) },
                                            onClose: { [weak self] i in self?.closeTab(i) },
                                            onNew: { [weak self] in self?.newTab() }))
    }

    static func same(_ a: Location, _ b: Location) -> Bool {
        a.path == b.path && a.session?.key == b.session?.key
    }

    @objc func goBack() {
        guard let previous = backStack.popLast() else { NSSound.beep(); return }
        forwardStack.append(location)
        pendingSelection = (location.path as NSString).lastPathComponent
        navigate(to: previous, recordHistory: false)
    }

    @objc func goForward() {
        guard let next = forwardStack.popLast() else { NSSound.beep(); return }
        backStack.append(location)
        navigate(to: next, recordHistory: false)
    }

    @objc func openSelected() {
        let entry: FileEntry
        if viewMode == .icons {
            guard let first = icons.selectedEntries.first else { return }
            entry = first
        } else {
            guard tableView.clickedRow >= 0 || tableView.selectedRow >= 0 else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row < entries.count else { return }
            entry = entries[row]
        }
        if entry.isDirectory {
            navigate(to: location.with(path: entry.path))
        } else if case .local = location {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        } else {
            editRemote(entry, with: nil)
        }
    }

    @objc func goUp() {
        let parent = location.parent
        guard parent != location.path else { return }
        let previous = (location.path as NSString).lastPathComponent
        navigate(to: location.with(path: parent))
        pendingSelection = previous
    }

    var pendingSelection: String?

    func reload() {
        loadTask?.cancel()
        isLoading = true
        let loc = location
        tableView.endMarking()
        // Reloading the same folder keeps what was selected (a finished transfer or a chmod reloads it).
        let keep = Set(tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].path : nil })
        // Show "Loading…" only if it takes longer than 300 ms, so fast folders don't flicker.
        let spinnerTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled && self.isLoading { self.showOverlay(.loading) }
        }
        loadTask = Task { @MainActor in
            defer { spinnerTask.cancel() }
            do {
                let list: [FileEntry]
                if let name = tag?.name {
                    let search = FinderTags.search
                    list = await Task.detached(priority: .userInitiated) { search(name).map { LocalFS.entry(at: $0) } }.value
                } else {
                    list = try await loc.list()
                }
                guard !Task.isCancelled else { return }
                isLoading = false
                autoReconnectTried = false
                allEntries = list
                // Expanded folders stay open, with fresh contents; ones that are gone close.
                for path in expanded.keys.sorted() {
                    expanded[path] = try? await loc.with(path: path).list()
                    guard !Task.isCancelled else { return }
                }
                applyFilterAndSort()
                showOverlay(entries.isEmpty ? .empty : nil)
                if let name = pendingSelection, viewMode == .icons { icons.select(name) }
                if let name = pendingSelection, let i = entries.firstIndex(where: { $0.name == name }) {
                    tableView.selectRowIndexes([i], byExtendingSelection: false)
                    tableView.scrollRowToVisible(i)
                } else if !keep.isEmpty, Self.same(loc, location) {
                    tableView.selectRowIndexes(IndexSet(entries.indices.filter { keep.contains(entries[$0].path) }), byExtendingSelection: false)
                }
                pendingSelection = nil
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                // A dropped connection gets one quiet reconnect before we show "Connection lost".
                if let session = loc.session, !session.isAlive, !autoReconnectTried {
                    autoReconnectTried = true
                    reconnectNow()
                    return
                }
                allEntries = []
                applyFilterAndSort()
                showOverlay(.error(error))
            }
            refreshChrome()
        }
    }

    /// A short-lived note in the status bar ("Saved index.html to web-1.").
    func flash(_ message: String) {
        flashMessage = message
        refreshChrome()
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            flashMessage = nil
            refreshChrome()
        }
    }

    /// Reopens this pane's server (with saved credentials) at the same folder.
    func reconnectNow() {
        guard let session = location.session else { return }
        let path = location.path
        showBusy("Reconnecting to \(session.label)…")
        Task { @MainActor in
            do {
                let live = try await session.live()
                showBusy(nil)
                navigate(to: .remote(live, path))
            } catch {
                showBusy(nil)
                allEntries = []
                applyFilterAndSort()
                showOverlay(.error(error))
            }
        }
    }

    func showBusy(_ message: String?) {
        busyMessage = message
        if let message { showOverlay(.busy(message)) } else { showOverlay(nil) }
        refreshChrome()
    }

    // MARK: - Overlay states

    enum Overlay {
        case loading, empty, busy(String), error(Error)
    }

    func showOverlay(_ overlay: Overlay?) {
        guard let overlay else {
            overlayHost.isHidden = true
            return
        }
        overlayHost.isHidden = false
        let view: AnyView
        switch overlay {
        case .loading:
            view = AnyView(VStack(spacing: Tokens.Space.s8) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(Tokens.Colors.textMuted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity))
        case let .busy(message):
            view = AnyView(VStack(spacing: Tokens.Space.s8) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(Tokens.Colors.textMuted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Tokens.Colors.bg))
        case .empty:
            view = AnyView(EmptyState(symbol: "folder", title: "This folder is empty",
                                      message: isRemote ? "Drag files here, or copy them from the other pane with F5." : "Nothing in here yet."))
        case let .error(error):
            if let session = location.session, !session.isAlive {
                view = AnyView(EmptyState(symbol: "bolt.horizontal.circle", title: "Connection lost",
                                          message: error.localizedDescription, tone: .danger,
                                          actionTitle: "Reconnect") { [weak self] in
                    guard let self else { return }
                    self.delegate?.paneRequestsReconnect(self)
                }.background(Tokens.Colors.bg))
            } else if case SFTPError.status(.permissionDenied, _, _) = error {
                view = AnyView(EmptyState(symbol: "lock", title: "No access",
                                          message: "Your account on this server can't open this folder.", tone: .danger)
                    .background(Tokens.Colors.bg))
            } else if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileReadNoPermissionError {
                view = AnyView(EmptyState(symbol: "lock", title: "No access",
                                          message: "macOS didn't let Shellpane read this folder. You can allow it in System Settings ▸ Privacy & Security ▸ Files and Folders.",
                                          tone: .danger).background(Tokens.Colors.bg))
            } else {
                view = AnyView(EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't open this folder",
                                          message: error.localizedDescription, tone: .danger,
                                          actionTitle: "Try Again") { [weak self] in self?.reload() }
                    .background(Tokens.Colors.bg))
            }
        }
        overlayHost.rootView = view
    }

    // MARK: - Chrome

    func refreshChrome() {
        refreshTabs()
        delegate?.paneSelectionChanged(self)
        let remote = location.session.map {
            let look = delegate?.appearance(of: $0, openedAs: openedAs) ?? (icon: nil, colour: $0.colour)
            return PathBar.Remote(user: $0.target.user ?? Recording.userName, host: $0.target.host, colour: look.colour, icon: look.icon)
        }
        let loc = location
        let bookmarked = tag == nil && (delegate?.pane(self, isBookmarked: loc.path) ?? false)
        pathHost.rootView = AnyView(PathBar(
            remote: remote, path: loc.path, isBookmarked: bookmarked, isEditing: !pathField.isHidden,
            tag: tag.map { ($0.name, $0.nsColor.map { Color(nsColor: $0) }) },
            onNavigate: { [weak self] path in self?.navigate(to: loc.with(path: path)) },
            onEdit: { [weak self] in self?.beginEditingPath() },
            onCopy: { [weak self] remoteForm in self?.copyFolderPath(remoteForm: remoteForm) },
            onToggleBookmark: { [weak self] in
                guard let self else { return }
                self.delegate?.pane(self, setBookmarked: !bookmarked, path: loc.path)
            }))

        let selected = selectedEntries
        let leading: String
        if let busyMessage {
            leading = busyMessage
        } else if let flashMessage {
            leading = flashMessage
        } else if isLoading {
            leading = "Loading…"
        } else if !filterText.isEmpty && selected.count <= 1 {
            leading = "Showing \(entries.count.formatted()) of \((showHidden ? allEntries.count : allEntries.filter { !$0.isHidden }.count).formatted()) · filter “\(filterText)”"
        } else if selected.isEmpty {
            leading = entries.count == 1 ? "1 item" : "\(entries.count.formatted()) items"
        } else {
            let bytes = selected.reduce(Int64(0)) { $0 + Int64($1.isDirectory ? 0 : ($1.attributes.size ?? 0)) }
            leading = "\(selected.count) of \(entries.count.formatted()) selected, " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        let trailing: String
        if let session = location.session {
            trailing = "SFTP · \(session.target.displayName)"
        } else if let free = LocalFS.freeSpace(at: location.path) {
            trailing = ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " available"
        } else {
            trailing = ""
        }
        statusHost.rootView = AnyView(StatusBar(leading: leading, trailing: trailing, busy: isLoading || busyMessage != nil))
        view.window?.title = tag?.name ?? ((location.path as NSString).lastPathComponent.isEmpty ? "/" : (location.path as NSString).lastPathComponent)
    }

    // MARK: - Data

    private func applyFilterAndSort() {
        // Rows move when folders open, close or re-sort, so selection and cursor follow the item, not the index.
        let selectedPaths = Set(tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].path : nil })
        let cursorPath = tableView.cursor >= 0 && tableView.cursor < entries.count ? entries[tableView.cursor].path : nil
        let top = sortedVisible(allEntries)
        var rows: [FileEntry] = [], rowDepths: [Int] = []
        func add(_ list: [FileEntry], depth: Int) {
            for e in list {
                rows.append(e)
                rowDepths.append(depth)
                if viewMode == .list, e.isDirectory, let children = expanded[e.path] { add(sortedVisible(children), depth: depth + 1) }
            }
        }
        add(top, depth: 0)
        entries = rows
        depths = rowDepths
        let keep = Set(icons.selectedEntries.map(\.name))
        tableView.reloadData()
        if !selectedPaths.isEmpty {
            tableView.selectRowIndexes(IndexSet(entries.indices.filter { selectedPaths.contains(entries[$0].path) }), byExtendingSelection: false)
        }
        if let cursorPath, let i = entries.firstIndex(where: { $0.path == cursorPath }) { tableView.setCursor(i) }
        if viewMode == .icons { icons.show(top, keepSelection: keep) }
        refreshChrome()
    }

    /// Hidden files and the quick filter applied, then sorted by the list's sort column, folders first.
    private func sortedVisible(_ list: [FileEntry]) -> [FileEntry] {
        var visible = showHidden ? list : list.filter { !$0.isHidden }
        if !filterText.isEmpty { visible = visible.filter { $0.name.localizedCaseInsensitiveContains(filterText) } }
        let descriptor = tableView.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        let ascending = descriptor.ascending
        return visible.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }  // folders first
            let ordered: Bool
            switch descriptor.key {
            case "size":
                let (x, y) = (a.attributes.size ?? 0, b.attributes.size ?? 0)
                ordered = x == y ? a.name.localizedStandardCompare(b.name) == .orderedAscending : x < y
            case "date":
                let (x, y) = (a.attributes.modificationTime ?? 0, b.attributes.modificationTime ?? 0)
                ordered = x == y ? a.name.localizedStandardCompare(b.name) == .orderedAscending : x < y
            case "kind":
                let (x, y) = (Self.kind(of: a), Self.kind(of: b))
                ordered = x == y ? a.name.localizedStandardCompare(b.name) == .orderedAscending : x.localizedStandardCompare(y) == .orderedAscending
            default:
                ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }

    // MARK: - Finder tags

    /// Lists everything with a Finder tag, as Finder does when you click it. Back returns to the folder.
    func showTag(_ t: FinderTag) {
        endEditingPath()
        backStack.append(location)
        forwardStack.removeAll()
        if viewMode == .columns { viewMode = .list }
        location = .local(NSHomeDirectory())
        tag = t
        expanded = [:]
        allEntries = []
        entries = []
        depths = []
        tableView.reloadData()
        refreshChrome()
        reload()
        delegate?.paneDidNavigate(self)
    }

    /// For actions that put something in this pane's folder: a tag view has none. Says so, and returns false.
    func acceptsNewItems() -> Bool {
        guard let tag else { return true }
        NSSound.beep()
        flash("This pane is showing the tag “\(tag.name)”. Open a folder to put things in it.")
        return false
    }

    // MARK: - Typing a path

    func beginEditingPath() {
        pathField.stringValue = location.path
        pathField.isHidden = false
        refreshChrome()
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    func endEditingPath() {
        guard !pathField.isHidden else { return }
        pathField.isHidden = true
        refreshChrome()
        if view.window?.firstResponder === pathField.currentEditor() {
            view.window?.makeFirstResponder(viewMode == .icons ? icons.collection : tableView)
        }
    }

    /// Return in the path field: a folder opens; a file opens its folder with the file selected; anything
    /// else keeps the field open and says so.
    func commitPath() {
        let loc = location
        let home = loc.session?.home ?? NSHomeDirectory()
        let path = RemotePath.resolve(pathField.stringValue, from: loc.path, home: home, acceptsHostPrefix: loc.session != nil)
        Task { @MainActor in
            switch await Self.kind(of: path, in: loc) {
            case .directory?:
                endEditingPath()
                navigate(to: loc.with(path: path))
            case .some:
                endEditingPath()
                pendingSelection = (path as NSString).lastPathComponent
                navigate(to: loc.with(path: RemotePath.parent(path)))
            case nil:
                NSSound.beep()
                flash("There's no “\(path)” \(loc.session.map { "on \($0.label)" } ?? "on this Mac").")
            }
        }
    }

    /// What's at `path` (following links), or nil if nothing is there or it can't be reached.
    static func kind(of path: String, in loc: Location) async -> FileType? {
        switch loc {
        case .local:
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            return isDir.boolValue ? .directory : .regular
        case let .remote(session, _):
            return try? await session.client.stat(path).fileType
        }
    }

    /// The path bar's copy button: this folder's path, or "host:/path" (with "user@" when known) for scp.
    func copyFolderPath(remoteForm: Bool) {
        var text = location.path
        if remoteForm, let target = location.session?.target {
            text = (target.user.map { $0 + "@" } ?? "") + target.host + ":" + location.path
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied “\(text)”.")
    }

    @objc func menuAddBookmark() {
        guard let folder = selectedEntries.first, folder.isDirectory else { return }
        delegate?.pane(self, setBookmarked: true, path: folder.path)
    }

    // MARK: - Folders open in place

    /// Shows or hides a folder's contents under it in the list (the disclosure triangle, → and ←).
    func setExpanded(_ open: Bool, row: Int) {
        guard viewMode == .list, row >= 0, row < entries.count else { return }
        let entry = entries[row]
        guard entry.isDirectory else { return }
        if !open {
            guard expanded[entry.path] != nil else { return }
            // Closing a folder closes the folders inside it too.
            expanded = expanded.filter { $0.key != entry.path && !$0.key.hasPrefix(entry.path + "/") }
            applyFilterAndSort()
            return
        }
        guard expanded[entry.path] == nil else { return }
        let loc = location
        Task { @MainActor in
            do {
                let list = try await loc.with(path: entry.path).list()
                guard Self.same(loc, location) else { return }
                expanded[entry.path] = list
                applyFilterAndSort()
            } catch {
                showProblem("Couldn't open “\(entry.name)”", error)
            }
        }
    }

    /// ←: closes an open folder; on anything inside one, goes to the folder that holds it.
    private func collapseOrGoToParent(row: Int) {
        guard row >= 0, row < entries.count else { return }
        if expanded[entries[row].path] != nil { setExpanded(false, row: row); return }
        guard depths[row] > 0, let parent = (0..<row).last(where: { depths[$0] == depths[row] - 1 }) else { return }
        tableView.selectRowIndexes([parent], byExtendingSelection: tableView.marking)
        tableView.setCursor(parent)
        tableView.scrollRowToVisible(parent)
    }

    @objc private func disclosureClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        setExpanded(sender.state == .on, row: row)
    }

    static func kind(of entry: FileEntry) -> String {
        if entry.attributes.fileType == .symlink { return entry.isDirectory ? "Folder link" : "Link" }
        if entry.isDirectory { return "Folder" }
        let ext = (entry.name as NSString).pathExtension
        if ext.isEmpty { return "File" }
        return UTType(filenameExtension: ext)?.localizedDescription?.capitalizedFirst ?? ext.uppercased() + " file"
    }

    /// Finder's own folder icon: follows the system's folder colour and appearance. Files keep symbols.
    static func folderIcon(size: CGFloat) -> NSImage {
        let image = (folderIconSource.copy() as? NSImage) ?? folderIconSource
        image.size = NSSize(width: size, height: size)
        return image
    }
    private static let folderIconSource = NSWorkspace.shared.icon(for: .folder)
    /// How far each level of an open folder is indented, as in Finder.
    static let indentStep: CGFloat = 16

    static func symbol(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return "film" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .text) || type.conforms(to: .script) { return "doc.text" }
        return "doc"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = CursorRowView()
        v.isCursor = self.tableView.marking && row == self.tableView.cursor
        return v
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilterAndSort()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshChrome()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < entries.count else { return nil }
        let entry = entries[row]
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PaneCellView) ?? makeCell(id)
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = entry.name
            let depth = row < depths.count ? depths[row] : 0
            cell.indent?.constant = Tokens.Space.s2 + CGFloat(depth) * Self.indentStep
            cell.disclosure?.isHidden = !entry.isDirectory || viewMode != .list
            cell.disclosure?.state = expanded[entry.path] != nil ? .on : .off
            cell.disclosure?.setAccessibilityLabel(expanded[entry.path] != nil ? "Hide contents of \(entry.name)" : "Show contents of \(entry.name)")
            cell.imageView?.image = entry.isDirectory ? Self.folderIcon(size: Tokens.Size.iconRow)
                : NSImage(systemSymbolName: Self.symbol(for: entry), accessibilityDescription: nil)
            cell.normalTint = Tokens.NSColors.textMuted
            cell.normalText = entry.isHidden ? Tokens.NSColors.textMuted : Tokens.NSColors.text
            cell.setAccessibilityLabel("\(entry.name), \(entry.isDirectory ? "folder" : "file")")
        case "size":
            cell.textField?.stringValue = entry.isDirectory ? "--" :
                ByteCountFormatter.string(fromByteCount: Int64(entry.attributes.size ?? 0), countStyle: .file)
        case "date":
            cell.textField?.stringValue = entry.attributes.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? ""
        default:
            cell.textField?.stringValue = Self.kind(of: entry)
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> PaneCellView {
        let cell = PaneCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.addSubview(text)
        cell.textField = text
        if id.rawValue == "name" {
            // The triangle keeps its space on files too, so names line up as in Finder.
            let disclosure = NSButton(title: "", target: self, action: #selector(disclosureClicked(_:)))
            disclosure.bezelStyle = .disclosure
            disclosure.setButtonType(.onOff)
            disclosure.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(disclosure)
            cell.disclosure = disclosure
            let indent = disclosure.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Tokens.Space.s2)
            cell.indent = indent
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                indent,
                disclosure.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                disclosure.widthAnchor.constraint(equalToConstant: 13),
                image.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: Tokens.Space.s2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: Tokens.Size.iconRow),
                image.heightAnchor.constraint(equalToConstant: Tokens.Size.iconRow),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: Tokens.Space.s6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Tokens.Space.s4).isActive = true
            cell.normalText = Tokens.NSColors.textMuted
            if id.rawValue == "size" { text.alignment = .right }
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Tokens.Space.s4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// The pane's overlay (loading, empty, errors). SwiftUI's hosting view keeps answering hit tests while
/// hidden, which swallowed every click on the file list underneath (BUG-006). Hidden means hidden.
final class OverlayHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Esc in the filter clears it; Return or ↓ goes to the list. In the path field, Return goes, Esc cancels,
/// and clicking away cancels too.
extension PaneViewController: NSSearchFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSControl) === pathField else { return }
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        if movement != NSTextMovement.return.rawValue { endEditingPath() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === pathField {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)): endEditingPath(); return true
            case #selector(NSResponder.insertNewline(_:)): commitPath(); return true
            default: return false
            }
        }
        guard control === filterField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            clearFilter()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            view.window?.makeFirstResponder(viewMode == .icons ? icons.collection : tableView)
            return true
        default:
            return false
        }
    }
}
