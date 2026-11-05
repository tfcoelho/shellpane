import AppKit
import ShellpaneCore
import ShellpaneUI
import SwiftUI

/// A row or column of panes (or of smaller splits), with draggable dividers. Plain frames and fractions, so
/// a layout's sizes mean exactly what they say: NSSplitView wouldn't hold positions set on nested column splits.
final class PaneSplit: NSView {
    static let thickness: CGFloat = 1
    /// How far from a divider a press still grabs it, each side.
    private static let grab: CGFloat = 3

    let axis: PaneLayout.Axis
    let items: [NSView]
    private(set) var sizes: [Double]
    /// Each item's least size along the split.
    private let minimums: [CGFloat]

    init(axis: PaneLayout.Axis, items: [NSView], sizes: [Double], minimums: [CGFloat]) {
        self.axis = axis
        self.items = items
        self.sizes = sizes
        self.minimums = minimums
        super.init(frame: .zero)
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = true
            item.autoresizingMask = []
            addSubview(item)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }   // the first item at the top, like reading order

    private var extent: CGFloat { axis == .row ? bounds.width : bounds.height }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    /// Each item's share of the space, then the least it can have, taken from those with room to spare.
    private func place() {
        let total = max(0, extent - Self.thickness * CGFloat(items.count - 1))
        var lengths = sizes.map { CGFloat($0) * total }
        for i in lengths.indices where lengths[i] < minimums[i] {
            var missing = minimums[i] - lengths[i]
            lengths[i] = minimums[i]
            for j in lengths.indices where j != i && lengths[j] > minimums[j] && missing > 0 {
                let take = min(missing, lengths[j] - minimums[j])
                lengths[j] -= take
                missing -= take
            }
        }
        var position: CGFloat = 0
        for (i, item) in items.enumerated() {
            let length = i == items.count - 1 ? max(0, extent - position) : lengths[i].rounded()
            item.frame = axis == .row ? NSRect(x: position, y: 0, width: length, height: bounds.height)
                                      : NSRect(x: 0, y: position, width: bounds.width, height: length)
            position += length + Self.thickness
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func dividerRect(_ i: Int) -> NSRect {
        let frame = items[i].frame
        return axis == .row ? NSRect(x: frame.maxX, y: 0, width: Self.thickness, height: bounds.height)
                            : NSRect(x: 0, y: frame.maxY, width: bounds.width, height: Self.thickness)
    }

    private func grabRect(_ i: Int) -> NSRect {
        axis == .row ? dividerRect(i).insetBy(dx: -Self.grab, dy: 0) : dividerRect(i).insetBy(dx: 0, dy: -Self.grab)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for i in items.indices.dropLast() { dividerRect(i).intersection(dirtyRect).fill() }
    }

    override func resetCursorRects() {
        for i in items.indices.dropLast() {
            addCursorRect(grabRect(i), cursor: axis == .row ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if items.indices.dropLast().contains(where: { grabRect($0).contains(local) }) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let i = items.indices.dropLast().first(where: { grabRect($0).contains(start) }), let window else { return }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { next, stop in
            guard let next, next.type == .leftMouseDragged else { stop.pointee = true; return }
            let p = convert(next.locationInWindow, from: nil)
            moveDivider(i, to: axis == .row ? p.x : p.y)
        }
    }

    /// Puts divider `i` at this position, as near as both its neighbours' minimums allow.
    func moveDivider(_ i: Int, to position: CGFloat) {
        let first = items[i].frame, second = items[i + 1].frame
        let begin = axis == .row ? first.minX : first.minY
        let end = axis == .row ? second.maxX : second.maxY
        let room = end - begin - Self.thickness
        guard room > 0 else { return }
        let length = min(max(position - begin, minimums[i]), max(room - minimums[i + 1], minimums[i]))
        let pair = sizes[i] + sizes[i + 1]
        sizes[i] = pair * Double(length / room)
        sizes[i + 1] = pair - sizes[i]
        place()
    }
}

/// The part of the window that holds the panes: nested splits built from a `PaneLayout`, or the start page
/// when there are none. Rebuilt on every layout change; the panes themselves keep their state.
@MainActor
final class PaneAreaController: NSViewController {
    /// A built layout: a pane's id, or a split with its children.
    private final class Node {
        let view: NSView
        let id: UUID?
        let children: [Node]

        init(view: NSView, id: UUID?, children: [Node] = []) {
            self.view = view
            self.id = id
            self.children = children
        }
    }

    /// Where a dragged pane would land. Sits above the panes and never takes a click.
    private final class DropPreview: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: Tokens.Radius.md, yRadius: Tokens.Radius.md)
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private var root: Node?
    private let startHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let preview = DropPreview()

    override func loadView() {
        let v = NSView()
        startHost.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(startHost)
        NSLayoutConstraint.activate([
            startHost.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            startHost.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            startHost.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            startHost.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        preview.isHidden = true
        v.addSubview(preview)
        view = v
    }

    /// What the window shows with no panes.
    func setStartPage(_ page: AnyView) {
        _ = view
        startHost.rootView = page
    }

    var showsStartPage: Bool { !startHost.isHidden }

    func show(_ layout: PaneLayout?, panes: [UUID: PaneViewController]) {
        _ = view
        root?.view.removeFromSuperview()
        root = nil
        for child in children {
            child.view.removeFromSuperview()
            if !panes.values.contains(where: { $0 === child }) { child.removeFromParent() }
        }
        startHost.isHidden = layout != nil
        guard let layout else { return }
        for pane in panes.values where pane.parent !== self { addChild(pane) }
        let node = build(layout, panes)
        node.view.translatesAutoresizingMaskIntoConstraints = true
        node.view.autoresizingMask = [.width, .height]
        node.view.frame = view.bounds
        view.addSubview(node.view, positioned: .below, relativeTo: preview)
        root = node
    }

    private func build(_ layout: PaneLayout, _ panes: [UUID: PaneViewController]) -> Node {
        switch layout {
        case let .pane(id):
            guard let pane = panes[id] else { return Node(view: NSView(), id: id) }
            return Node(view: pane.view, id: id)
        case let .split(axis, children, sizes):
            let nodes = children.map { build($0, panes) }
            let minimums = children.map { child -> CGFloat in
                let least = child.minimumSize(paneWidth: Tokens.Size.paneMinWidth, paneHeight: Tokens.Size.paneMinHeight)
                return CGFloat(axis == .row ? least.width : least.height)
            }
            return Node(view: PaneSplit(axis: axis, items: nodes.map(\.view), sizes: sizes, minimums: minimums), id: nil, children: nodes)
        }
    }

    /// The layout as it is on screen now, with any dividers the person has dragged.
    func currentLayout() -> PaneLayout? { root.flatMap(read) }

    private func read(_ node: Node) -> PaneLayout? {
        if let id = node.id { return .pane(id) }
        guard let split = node.view as? PaneSplit else { return nil }
        return .split(split.axis, node.children.compactMap(read), sizes: split.sizes)
    }

    /// For a test: the outermost split, whose dividers it can move.
    var rootSplit: PaneSplit? { root?.view as? PaneSplit }

    /// The part of a pane you can see (below the toolbar), in this view's coordinates.
    func frame(of pane: PaneViewController) -> NSRect {
        pane.view.convert(pane.view.safeAreaRect, to: view)
    }

    /// The whole area below the toolbar.
    var visibleBounds: NSRect { view.safeAreaRect }

    func showPreview(_ rect: NSRect?) {
        guard let rect else {
            preview.isHidden = true
            return
        }
        if preview.isHidden {
            preview.frame = rect
            preview.isHidden = false
        } else if preview.frame != rect {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                preview.animator().frame = rect
            }
        }
        view.addSubview(preview, positioned: .above, relativeTo: nil)
    }
}
