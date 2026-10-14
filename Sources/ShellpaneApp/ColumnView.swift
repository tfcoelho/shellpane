import AppKit
import ShellpaneUI
import SFTPKit

/// Column view (⌘3): Finder-style columns from the pane's folder. Lists load in the background,
/// local or remote alike, and each column fills in when its listing arrives.
@MainActor
final class ColumnController: NSObject, NSBrowserDelegate {
    let browser = NSBrowser()
    private(set) var root: String = "/"
    private var location: Location?
    private var showHidden = false
    private var children: [String: [FileEntry]] = [:]
    private var entries: [String: FileEntry] = [:]
    private var loading: Set<String> = []
    private var failed: [String: String] = [:]

    /// The deepest folder the person has opened, and what's selected in it.
    var onSelectionChange: (_ folder: String, _ selected: [FileEntry]) -> Void = { _, _ in }
    var onOpenFile: (FileEntry) -> Void = { _ in }

    override init() {
        super.init()
        browser.delegate = self
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.doubleAction = #selector(doubleClicked)
        browser.allowsMultipleSelection = true
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.isTitled = false
        browser.minColumnWidth = 180
        browser.setDefaultColumnWidth(220)
        browser.columnResizingType = .userColumnResizing
        browser.setAccessibilityLabel("Folders and files in columns")
    }

    func show(_ location: Location, showHidden: Bool) {
        let rootChanged = self.location.map { !PaneViewController.same($0, location) } ?? true
        self.location = location
        self.showHidden = showHidden
        if rootChanged {
            root = location.path
            children.removeAll()
            entries.removeAll()
            failed.removeAll()
        }
        browser.loadColumnZero()
    }

    /// Forget cached listings (after a change on disk) and reload what's on screen.
    func refresh() {
        children.removeAll()
        failed.removeAll()
        let path = browser.path()
        browser.loadColumnZero()
        browser.setPath(path)
    }

    var selectedEntries: [FileEntry] {
        (browser.selectionIndexPaths).compactMap { browser.item(at: $0) as? String }.compactMap { entries[$0] }
    }

    // MARK: Loading

    private func list(_ path: String) -> [FileEntry]? {
        if let cached = children[path] { return cached }
        guard let location, !loading.contains(path), failed[path] == nil else { return nil }
        loading.insert(path)
        let target = location.with(path: path)
        Task { @MainActor in
            defer { loading.remove(path) }
            do {
                let list = try await target.list()
                let visible = (showHidden ? list : list.filter { !$0.isHidden })
                    .filter { !$0.name.hasSuffix(partialSuffix) }
                    .sorted { a, b in
                        if a.isDirectory != b.isDirectory { return a.isDirectory }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                children[path] = visible
                for e in visible { entries[e.path] = e }
            } catch {
                failed[path] = error.localizedDescription
                children[path] = []
            }
            // Reload just the column that shows this folder.
            for col in 0...max(0, browser.lastColumn) where columnFolder(col) == path {
                browser.reloadColumn(col)
            }
        }
        return nil
    }

    private func columnFolder(_ col: Int) -> String? {
        col == 0 ? root : (browser.selectedRow(inColumn: col - 1) >= 0 ? browser.item(atRow: browser.selectedRow(inColumn: col - 1), inColumn: col - 1) as? String : nil)
    }

    // MARK: NSBrowserDelegate (item-based)

    func rootItem(for browser: NSBrowser) -> Any? { root as NSString }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let path = (item as? String) ?? (item as? NSString).map({ $0 as String }) else { return 0 }
        return list(path)?.count ?? 0
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let path = (item as? String) ?? root
        return (children[path]?[index].path ?? "") as NSString
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let path = item as? String, let e = entries[path] else { return false }
        return !e.isDirectory
    }

    /// Item-based browsers use plain text cells whatever cell class is set, so the icon can't be a cell
    /// image (BUG-007). It goes into the text instead, as an inline attachment before the name.
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        guard let path = item as? String else { return nil }
        guard let e = entries[path] else { return (path as NSString).lastPathComponent }
        let config = NSImage.SymbolConfiguration(pointSize: Tokens.Size.iconRow - 3, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Tokens.NSColors.textMuted]))
        let line = NSMutableAttributedString()
        let icon = e.isDirectory ? PaneViewController.folderIcon(size: Tokens.Size.iconRow)
            : NSImage(systemSymbolName: PaneViewController.symbol(for: e), accessibilityDescription: nil)?.withSymbolConfiguration(config)
        if let symbol = icon {
            // A fixed-width box, so names line up whatever the symbol's width.
            let box = NSSize(width: Tokens.Size.iconRow + 4, height: max(symbol.size.height, Tokens.Size.iconRow - 2))
            let image = NSImage(size: box, flipped: false) { rect in
                symbol.draw(in: NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - box.height) / 2, width: box.width, height: box.height)
            line.append(NSAttributedString(attachment: attachment))
            line.append(NSAttributedString(string: "  "))
        }
        line.append(NSAttributedString(string: e.name, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        return line
    }

    // MARK: Actions

    @objc private func selectionChanged() {
        let selected = selectedEntries
        var folder = root
        if let last = selected.last {
            folder = last.isDirectory && selected.count == 1 ? last.path : RemotePath.parent(last.path)
        } else if let path = columnFolder(browser.selectedColumn + 1) {
            folder = path
        }
        onSelectionChange(folder, selected)
    }

    @objc private func doubleClicked() {
        guard let e = selectedEntries.first, !e.isDirectory else { return }
        onOpenFile(e)
    }
}
