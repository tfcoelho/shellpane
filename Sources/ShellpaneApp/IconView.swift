import AppKit
import ShellpaneUI
import SFTPKit

/// Icon view (⌘2): the pane's files as a grid. Same listing, keys and context menu as the list.
/// Sized like Finder's icon view at its defaults: 64 pt icons, 12 pt names, a fixed grid from the left.
enum IconMetrics {
    static let icon: CGFloat = 64
    static let font: CGFloat = 12
    static let item = NSSize(width: 112, height: 108)
    static let gap: CGFloat = 6
}

/// A flow layout that keeps Finder's fixed grid: rows start at the left and keep the same gap, instead
/// of spreading items out to fill each row.
final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let attributes = super.layoutAttributesForElements(in: rect).compactMap { $0.copy() as? NSCollectionViewLayoutAttributes }
        var x = sectionInset.left
        var rowY: CGFloat = -.greatestFiniteMagnitude
        for a in attributes where a.representedElementCategory == .item {
            if abs(a.frame.minY - rowY) > 1 { x = sectionInset.left; rowY = a.frame.minY }
            a.frame.origin.x = x
            x += a.frame.width + minimumInteritemSpacing
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let base = super.layoutAttributesForItem(at: indexPath) else { return nil }
        return layoutAttributesForElements(in: base.frame.insetBy(dx: -.greatestFiniteMagnitude / 4, dy: 0))
            .first { $0.indexPath == indexPath } ?? base
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}

final class IconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("IconItem")
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var iconSide: [NSLayoutConstraint] = []

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = Tokens.Radius.md
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: IconMetrics.font)
        v.addSubview(icon)
        v.addSubview(label)
        iconSide = [icon.widthAnchor.constraint(equalToConstant: IconMetrics.icon),
                    icon.heightAnchor.constraint(equalToConstant: IconMetrics.icon)]
        NSLayoutConstraint.activate(iconSide + [
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: Tokens.Space.s6),
            icon.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: Tokens.Space.s2),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: Tokens.Space.s4),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -Tokens.Space.s4),
        ])
        view = v
    }

    func show(_ e: FileEntry, zoom: CGFloat) {
        let side = (IconMetrics.icon * zoom).rounded()
        iconSide.forEach { $0.constant = side }
        label.font = .systemFont(ofSize: (IconMetrics.font * zoom).rounded())
        icon.image = PaneViewController.fileIcon(for: e, size: side)
        icon.contentTintColor = Tokens.NSColors.textMuted
        label.stringValue = e.name
        label.textColor = e.isHidden ? Tokens.NSColors.textMuted : Tokens.NSColors.text
        view.setAccessibilityLabel("\(e.name), \(e.isDirectory ? "folder" : "file")")
        updateSelection()
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        view.layer?.backgroundColor = isSelected ? Tokens.NSColors.selectionInactive.cgColor : NSColor.clear.cgColor
    }
}

/// Keys like the list: ⌘↓ / double-click open, ⌘↑ up, Return rename, ⌘⌫ delete, F5 / F6, ⌘C / ⌘V.
final class IconCollectionView: NSCollectionView {
    weak var pane: PaneViewController?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { pane?.openSelected() }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 125 where mods == .command: pane?.openSelected()
        case 126 where mods == .command: pane?.goUp()
        case 36 where mods.isEmpty, 76 where mods.isEmpty: pane?.renameSelected()
        case 51 where mods == .command: pane?.deleteSelected()
        case 96: pane.map { $0.delegate?.paneRequestsCopyToOtherPane($0) }
        case 97: pane.map { $0.delegate?.paneRequestsMoveToOtherPane($0) }
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let pane { pane.delegate?.paneDidBecomeActive(pane) }
        return ok
    }

    @objc func copy(_ sender: Any?) { pane?.copyToClipboard() }
    @objc func paste(_ sender: Any?) { pane?.pasteFromClipboard() }
}

@MainActor
final class IconController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let scrollView = NSScrollView()
    let collection = IconCollectionView()
    private var entries: [FileEntry] = []
    var onSelectionChange: () -> Void = {}
    /// The pane's ⌘+ / ⌘- size: icons, labels and the grid grow together.
    var zoom: CGFloat = 1 {
        didSet {
            guard zoom != oldValue else { return }
            (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize = Self.itemSize(zoom)
            let keep = collection.selectionIndexPaths
            collection.reloadData()
            collection.selectionIndexPaths = keep
        }
    }
    private static func itemSize(_ zoom: CGFloat) -> NSSize {
        NSSize(width: (IconMetrics.item.width * zoom).rounded(), height: (IconMetrics.item.height * zoom).rounded())
    }

    override init() {
        super.init()
        let layout = LeftAlignedFlowLayout()
        layout.itemSize = Self.itemSize(zoom)
        layout.minimumInteritemSpacing = IconMetrics.gap
        layout.minimumLineSpacing = IconMetrics.gap
        layout.sectionInset = NSEdgeInsets(top: Tokens.Space.s12, left: Tokens.Space.s12, bottom: Tokens.Space.s12, right: Tokens.Space.s12)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [NSColor.alternatingContentBackgroundColors[0]]
        collection.register(IconItem.self, forItemWithIdentifier: IconItem.id)
        collection.dataSource = self
        collection.delegate = self
        collection.setAccessibilityLabel("Files as icons")
        scrollView.documentView = collection
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    func show(_ entries: [FileEntry], keepSelection names: Set<String> = []) {
        self.entries = entries
        collection.reloadData()
        let keep = Set(entries.indices.filter { names.contains(entries[$0].name) }.map { IndexPath(item: $0, section: 0) })
        if !keep.isEmpty { collection.selectionIndexPaths = keep }
    }

    var selectedEntries: [FileEntry] {
        collection.selectionIndexPaths.sorted().compactMap { $0.item < entries.count ? entries[$0.item] : nil }
    }

    func select(_ name: String) {
        guard let i = entries.firstIndex(where: { $0.name == name }) else { return }
        let path = IndexPath(item: i, section: 0)
        collection.selectionIndexPaths = [path]
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.id, for: indexPath)
        if let icon = item as? IconItem, indexPath.item < entries.count { icon.show(entries[indexPath.item], zoom: zoom) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { onSelectionChange() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { onSelectionChange() }
}
