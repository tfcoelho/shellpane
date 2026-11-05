import AppKit
import SFTPKit
import ShellpaneCore
import ShellpaneUI
import SSHProcess
import SwiftUI
import TransferKit

/// The window's panes: up to `PaneLayout.maxPanes` of them, arranged by a `PaneLayout`. Splitting, closing, presets, dragging panes
/// and tabs around, choosing where a transfer goes, and coming back as they were after a relaunch.
extension MainWindowController {
    // MARK: - Making and arranging panes

    /// A new pane, not yet in the layout.
    func makePane(location: Location = .local(NSHomeDirectory()), id: UUID = UUID(), showsStart: Bool = false) -> PaneViewController {
        let pane = PaneViewController(location: location, id: id)
        pane.delegate = self
        paneByID[id] = pane
        _ = pane.view
        if panes.first?.showHidden == true { pane.showHidden = true }
        if showsStart { pane.setShowsStart(true) }
        return pane
    }

    /// Arranges the window. `focus` gets the keyboard; otherwise the active pane keeps it if it's still here.
    func setLayout(_ new: PaneLayout?, focus: PaneViewController? = nil) {
        growWindow(toFit: new)
        layout = new
        let ids = Set(new?.paneIDs ?? [])
        paneByID = paneByID.filter { ids.contains($0.key) }
        let minimum = new?.minimumSize(paneWidth: Tokens.Size.paneMinWidth, paneHeight: Tokens.Size.paneMinHeight)
        areaItem?.minimumThickness = max(CGFloat(minimum?.width ?? 0), Tokens.Size.paneMinWidth)
        if let window, area.view.bounds.width > 0 {
            window.minSize = NSSize(width: max(Tokens.Size.windowMinWidth, CGFloat(minimum?.width ?? 0) + window.frame.width - area.view.bounds.width),
                                    height: max(Tokens.Size.windowMinHeight, CGFloat(minimum?.height ?? 0) + window.frame.height - area.view.bounds.height))
        }
        area.show(new, panes: paneByID)
        updateKeyLoop()
        let next = focus ?? activePane.flatMap { paneByID[$0.paneID] } ?? panes.last
        if let next {
            paneDidBecomeActive(next)
            window?.makeFirstResponder(next.focusView)
        } else {
            activePane = nil
            window?.title = "Shellpane"
            updateHistoryButtons()
        }
        savePanes()
    }

    /// Tab goes round the panes in reading order.
    func updateKeyLoop() {
        let all = panes
        for (i, pane) in all.enumerated() {
            pane.setNextKeyView(all[(i + 1) % all.count].focusView)
        }
    }

    /// The layout with any dividers the person has moved.
    private var currentLayout: PaneLayout? { area.currentLayout() ?? layout }

    private var paneSpaceOnScreen: NSSize? {
        guard let window, let screen = window.screen ?? NSScreen.main else { return nil }
        let chrome = NSSize(width: window.frame.width - area.view.bounds.width, height: window.frame.height - area.view.bounds.height)
        return NSSize(width: screen.visibleFrame.width - chrome.width, height: screen.visibleFrame.height - chrome.height)
    }

    /// Whether every pane of this layout could reach its minimum size on this screen.
    func fits(_ candidate: PaneLayout) -> Bool {
        guard let space = paneSpaceOnScreen else { return true }
        let need = candidate.minimumSize(paneWidth: Tokens.Size.paneMinWidth, paneHeight: Tokens.Size.paneMinHeight)
        return CGFloat(need.width) <= space.width && CGFloat(need.height) <= space.height
    }

    private func growWindow(toFit candidate: PaneLayout?) {
        guard let candidate, let window, let screen = window.screen ?? NSScreen.main, area.view.bounds.width > 0 else { return }
        let need = candidate.minimumSize(paneWidth: Tokens.Size.paneMinWidth, paneHeight: Tokens.Size.paneMinHeight)
        let extraWidth = max(0, CGFloat(need.width) - area.view.bounds.width)
        let extraHeight = max(0, CGFloat(need.height) - area.view.bounds.height)
        guard extraWidth > 0 || extraHeight > 0 else { return }
        var frame = window.frame
        frame.size.width += extraWidth
        frame.size.height += extraHeight
        frame.origin.y -= extraHeight
        let visible = screen.visibleFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    // MARK: - Split, close, presets

    /// A new pane beside the active one, showing the start page.
    @discardableResult
    func split(_ edge: PaneLayout.Edge, of target: PaneViewController? = nil) -> PaneViewController? {
        guard let current = currentLayout else {
            let pane = makePane(showsStart: true)
            setLayout(.pane(pane.paneID), focus: pane)
            return pane
        }
        guard panes.count < PaneLayout.maxPanes else {
            NSSound.beep()
            activePane?.flash("Six panes is the most a window holds.")
            return nil
        }
        guard let beside = target ?? activePane ?? panes.last else { return nil }
        let id = UUID()
        let next = current.inserting(id, beside: beside.paneID, at: edge)
        guard fits(next) else {
            NSSound.beep()
            activePane?.flash("There's no room for another pane on this screen.")
            return nil
        }
        let pane = makePane(id: id, showsStart: true)
        setLayout(next, focus: pane)
        return pane
    }

    func closePane(_ pane: PaneViewController) {
        guard paneByID[pane.paneID] != nil else { return }
        // The neighbour in reading order takes over as the active pane.
        var focus: PaneViewController?
        if activePane === pane, let i = panes.firstIndex(where: { $0 === pane }) {
            let rest = panes.filter { $0 !== pane }
            focus = rest.isEmpty ? nil : rest[min(i, rest.count - 1)]
            activePane = nil
        }
        setLayout(currentLayout?.removing(pane.paneID), focus: focus)
    }

    /// One of the arrangements in View › Layout. New panes are added as needed; panes beyond what it holds
    /// aren't lost, their folders become tabs of the last pane.
    func apply(_ preset: PaneLayout.Preset) {
        var all = panes
        var created: PaneViewController?
        var ids = all.map(\.paneID)
        while ids.count < preset.paneCount { ids.append(UUID()) }
        guard fits(preset.layout(ids)) else {
            NSSound.beep()
            activePane?.flash("There's no room for “\(preset.title)” on this screen.")
            return
        }
        for id in ids.dropFirst(all.count) {
            let pane = makePane(id: id, showsStart: true)
            all.append(pane)
            created = created ?? pane
        }
        let kept = Array(all.prefix(preset.paneCount))
        if let last = kept.last {
            for extra in all.dropFirst(preset.paneCount) where !extra.showsStart { last.adopt(extra.currentTabs()) }
        }
        let keptActive = activePane.flatMap { a in kept.contains { $0 === a } ? a : nil }
        setLayout(preset.layout(kept.map(\.paneID)), focus: created ?? keptActive ?? kept.last)
    }

    /// ⌥⌘ and an arrow: the nearest pane that way, overlapping the active one if there is one.
    func focusPane(_ edge: PaneLayout.Edge) {
        guard let active = activePane else { return }
        let from = area.frame(of: active)
        let candidates: [(PaneViewController, NSRect)] = panes.filter { $0 !== active }.map { ($0, area.frame(of: $0)) }.filter { _, r in
            switch edge {
            case .left: r.maxX <= from.minX + 1
            case .right: r.minX >= from.maxX - 1
            case .top: r.minY >= from.maxY - 1
            case .bottom: r.maxY <= from.minY + 1
            }
        }
        func overlaps(_ r: NSRect) -> Bool {
            edge.axis == .row ? r.maxY > from.minY && r.minY < from.maxY : r.maxX > from.minX && r.minX < from.maxX
        }
        func distance(_ r: NSRect) -> CGFloat {
            hypot(r.midX - from.midX, r.midY - from.midY) - (overlaps(r) ? 10_000 : 0)
        }
        guard let next = candidates.min(by: { distance($0.1) < distance($1.1) })?.0 else {
            NSSound.beep()
            return
        }
        window?.makeFirstResponder(next.focusView)
        paneDidBecomeActive(next)
    }

    // MARK: - Dragging panes and tabs

    enum DropTarget: Equatable {
        case beside(UUID, PaneLayout.Edge)
        case outer(PaneLayout.Edge)
        case merge(UUID)
    }

    func paneDragged(_ pane: PaneViewController, tab: Int?, phase: PaneDragPhase) {
        switch phase {
        case .changed:
            if drag == nil { beginDrag(pane, tab: tab) }
            guard let window else { return }
            updateDrag(at: area.view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        case .ended:
            endDrag()
        }
    }

    func beginDrag(_ pane: PaneViewController, tab: Int?) {
        // A tab that's the pane's only one moves the whole pane.
        let draggedTab = pane.tabs.count > 1 ? tab : nil
        drag = PaneDrag(pane: pane, tab: draggedTab)
        if draggedTab == nil { pane.view.alphaValue = 0.6 }
        drag?.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancelDrag()
            return nil
        }
    }

    func updateDrag(at point: NSPoint) {
        guard var d = drag else { return }
        d.target = dropTarget(at: point, for: d)
        drag = d
        area.showPreview(d.target.flatMap(previewRect))
    }

    /// Near the outside of the whole area: along that side. Over a pane: the nearest edge splits it,
    /// the middle joins it as tabs.
    private func dropTarget(at point: NSPoint, for d: PaneDrag) -> DropTarget? {
        guard let current = layout else { return nil }
        let isTab = d.tab != nil
        let bounds = area.visibleBounds
        let outerBand: CGFloat = 28
        var outer: PaneLayout.Edge?
        if bounds.contains(point) {
            if point.x - bounds.minX < outerBand { outer = .left }
            else if bounds.maxX - point.x < outerBand { outer = .right }
            else if bounds.maxY - point.y < outerBand { outer = .top }
            else if point.y - bounds.minY < outerBand { outer = .bottom }
        }
        let newID = UUID()
        if let outer, panes.count > 1 || isTab {
            let candidate = isTab ? current.inserting(newID, atOuter: outer) : current.moving(d.pane.paneID, toOuter: outer)
            if (!isTab || panes.count < PaneLayout.maxPanes), fits(candidate) { return .outer(outer) }
        }
        guard let over = panes.first(where: { area.frame(of: $0).contains(point) }) else { return nil }
        let frame = area.frame(of: over)
        let edge = nearestEdge(of: frame, to: point)
        if over === d.pane {
            // A pane can't land on itself, but a tab can split its own pane.
            guard isTab, let edge, panes.count < PaneLayout.maxPanes else { return nil }
            let candidate = current.inserting(newID, beside: over.paneID, at: edge)
            return fits(candidate) ? .beside(over.paneID, edge) : nil
        }
        guard let edge else { return .merge(over.paneID) }
        if isTab, panes.count >= PaneLayout.maxPanes { return .merge(over.paneID) }
        let candidate = isTab ? current.inserting(newID, beside: over.paneID, at: edge)
                              : current.moving(d.pane.paneID, beside: over.paneID, at: edge)
        return fits(candidate) ? .beside(over.paneID, edge) : .merge(over.paneID)
    }

    /// The edge whose band `point` is in, or nil for the middle.
    private func nearestEdge(of frame: NSRect, to point: NSPoint) -> PaneLayout.Edge? {
        let x = (point.x - frame.minX) / max(frame.width, 1), y = (point.y - frame.minY) / max(frame.height, 1)
        let distances: [(PaneLayout.Edge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, 1 - y), (.bottom, y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.28 else { return nil }
        return nearest.0
    }

    private func previewRect(_ target: DropTarget) -> NSRect? {
        func half(_ r: NSRect, _ edge: PaneLayout.Edge) -> NSRect {
            switch edge {
            case .left: NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
            case .right: NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
            case .top: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
            case .bottom: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
            }
        }
        func frame(_ id: UUID) -> NSRect? { paneByID[id].map(area.frame(of:)) }
        switch target {
        case let .beside(id, edge): return frame(id).map { half($0, edge) }
        case let .outer(edge): return half(area.visibleBounds, edge)
        case let .merge(id): return frame(id)
        }
    }

    func cancelDrag() {
        guard let d = drag else { return }
        finishDrag(d)
    }

    private func finishDrag(_ d: PaneDrag) {
        if let monitor = d.monitor { NSEvent.removeMonitor(monitor) }
        d.pane.view.alphaValue = 1
        area.showPreview(nil)
        drag = nil
    }

    func endDrag() {
        guard let d = drag else { return }
        finishDrag(d)
        guard let target = d.target, let current = currentLayout else { return }
        if let tab = d.tab {
            drop(tab: tab, of: d.pane, on: target, in: current)
        } else {
            drop(pane: d.pane, on: target, in: current)
        }
    }

    private func drop(pane: PaneViewController, on target: DropTarget, in current: PaneLayout) {
        switch target {
        case let .beside(id, edge): setLayout(current.moving(pane.paneID, beside: id, at: edge), focus: pane)
        case let .outer(edge): setLayout(current.moving(pane.paneID, toOuter: edge), focus: pane)
        case let .merge(id):
            guard let into = paneByID[id] else { return }
            if !pane.showsStart { into.adopt(pane.currentTabs()) }
            activePane = into
            setLayout(current.removing(pane.paneID), focus: into)
        }
    }

    private func drop(tab index: Int, of pane: PaneViewController, on target: DropTarget, in current: PaneLayout) {
        if case let .merge(id) = target {
            guard let into = paneByID[id], let tab = pane.removeTab(at: index) else { return }
            into.adopt([tab])
            window?.makeFirstResponder(into.focusView)
            paneDidBecomeActive(into)
            savePanes()
            return
        }
        guard let tab = pane.removeTab(at: index) else { return }
        let id = UUID()
        let next: PaneLayout
        switch target {
        case let .beside(beside, edge): next = current.inserting(id, beside: beside, at: edge)
        case let .outer(edge): next = current.inserting(id, atOuter: edge)
        case .merge: return
        }
        let new = makePane(location: tab.location, id: id)
        new.restoreHistory(of: tab)
        setLayout(next, focus: new)
    }

    // MARK: - Choosing a destination

    private func place(of pane: PaneViewController) -> String {
        guard let target = pane.location.session?.target else { return pane.location.path }
        return (target.user.map { $0 + "@" } ?? "") + target.host + ":" + pane.location.path
    }

    /// Why files can't go to this pane; nil if they can.
    private func transferProblem(_ pane: PaneViewController, from source: PaneViewController) -> String? {
        if pane.showsStart { return "No folder open here yet" }
        if pane.showsTag { return "Showing a tag, not a folder" }
        if PaneViewController.same(pane.location, source.location) { return "Same folder" }
        return nil
    }

    /// F5 / F6: with exactly one other pane there's nothing to ask, so it goes straight there. Otherwise, or
    /// from the toolbar button (`alwaysAsk`), the picker.
    func transfer(_ mode: TransferBatch.Mode, alwaysAsk: Bool = false) {
        guard let source = activePane else { NSSound.beep(); return }
        let entries = source.selectedEntries
        guard !entries.isEmpty else { NSSound.beep(); return }
        let others = panes.filter { $0 !== source }
        if !alwaysAsk, others.count == 1 {
            guard others[0].acceptsNewItems() else { return }
            send(mode, entries, from: source, to: others[0])
            return
        }
        let verb = mode == .move ? "Move" : "Copy"
        let items = entries.count == 1 ? "“\(entries[0].name)”" : "\(entries.count) items"
        showPicker(source: source, sourceText: "\(verb == "Move" ? "Moving" : "Copying") \(items) from here",
                   actionText: "\(verb) \(items) here",
                   problem: { [unowned self] in transferProblem($0, from: source) },
                   openPane: others.isEmpty ? { [weak self] in self?.split(.right, of: source) } : nil) { [weak self] dest in
            self?.send(mode, entries, from: source, to: dest)
        }
    }

    private func send(_ mode: TransferBatch.Mode, _ entries: [FileEntry], from source: PaneViewController, to dest: PaneViewController) {
        TransferCenter.shared.start(mode, entries, from: source.location, to: dest.location) { [weak source, weak dest] in
            dest?.reload()
            if mode == .move { source?.reload() }
        }
        showActivity(nil)
    }

    func showPicker(source: PaneViewController?, sourceText: String?, actionText: String,
                    problem: (PaneViewController) -> String?, openPane: (() -> Void)?,
                    choose: @escaping (PaneViewController) -> Void) {
        guard let window, picker == nil else { return }
        let options = panes.filter { $0 !== source }.map {
            TransferPicker.Option(pane: $0, place: place(of: $0), problem: problem($0))
        }
        let picker = TransferPicker(parent: window, source: source, sourceText: sourceText, actionText: actionText, options: options,
                                    onChoose: choose, onOpenPane: openPane,
                                    onDismiss: { [weak self] in self?.picker = nil })
        self.picker = picker
        picker.show()
    }

    // MARK: - Coming back as you left them

    /// What's saved for a pane. A server pane comes back offering to reconnect rather than logging in by
    /// itself: at launch that could mean a surprise Touch ID or password prompt, once per pane.
    private struct SavedPane: Codable {
        var id: UUID
        var favorite: String?
        var alias: String?
        var isLocal: Bool
        var path: String
        var viewMode: String
        var zoom: Double
        var showsStart: Bool
    }

    private struct SavedPanes: Codable {
        var layout: PaneLayout?
        var panes: [SavedPane]
        var active: UUID?
    }

    private static let savedPanesKey = "ShellpanePanes"

    func savePanes() {
        guard !isScripted, let data = encodedPanes() else { return }
        UserDefaults.standard.set(data, forKey: Self.savedPanesKey)
    }

    func encodedPanes() -> Data? {
        let saved = SavedPanes(layout: currentLayout, panes: panes.map { pane in
            var s = SavedPane(id: pane.paneID, isLocal: pane.location.session == nil, path: pane.location.path,
                              viewMode: pane.viewMode.rawValue, zoom: Double(pane.zoom), showsStart: pane.showsStart)
            switch pane.location.session == nil ? nil : bookmarkPlace(for: pane.location) {
            case let .favorite(id)?: s.favorite = id
            case let .sshAlias(alias)?: s.alias = alias
            default: break
            }
            return s
        }, active: activePane?.paneID)
        return try? JSONEncoder().encode(saved)
    }

    /// Back to how the panes were. First launch, or with nothing saved: no panes, just the start page.
    func restorePanes() { restorePanes(from: UserDefaults.standard.data(forKey: Self.savedPanesKey)) }

    func restorePanes(from data: Data?) {
        guard let data,
              let saved = try? JSONDecoder().decode(SavedPanes.self, from: data), let layout = saved.layout else {
            setLayout(nil)
            return
        }
        let home = NSHomeDirectory()
        for s in saved.panes where layout.contains(s.id) {
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: s.path, isDirectory: &isFolder) && isFolder.boolValue
            let pane = makePane(location: .local(s.isLocal && exists ? s.path : home), id: s.id, showsStart: s.showsStart || !s.isLocal)
            if PaneViewController.zoomSteps.contains(CGFloat(s.zoom)) { pane.zoom = CGFloat(s.zoom) }
            if let mode = PaneViewController.ViewMode(rawValue: s.viewMode) { pane.viewMode = mode }
            if !s.isLocal, !s.showsStart { offerReconnect(pane, s) }
        }
        // Anything that didn't come back leaves the layout, so a damaged save can't leave a hole.
        var cleaned: PaneLayout? = layout
        for id in layout.paneIDs where paneByID[id] == nil { cleaned = cleaned?.removing(id) }
        setLayout(cleaned, focus: saved.active.flatMap { paneByID[$0] })
    }

    private func offerReconnect(_ pane: PaneViewController, _ s: SavedPane) {
        if let id = s.favorite, let fav = sidebarModel.favorites.first(where: { $0.id == id }) {
            pane.resume = StartPage.Resume(title: fav.name, path: s.path) { [weak self] in self?.connect(fav, path: s.path) }
        } else if let alias = s.alias {
            pane.resume = StartPage.Resume(title: alias, path: s.path) { [weak self] in
                self?.connect(to: SSHTarget(host: alias), key: "alias:" + alias, path: s.path)
            }
        }
        pane.refreshStartPage()
    }

    // MARK: - PaneDelegate: the start page

    func startPage(for pane: PaneViewController) -> AnyView {
        AnyView(StartPage(model: sidebarModel, resume: pane.resume,
                          onActivate: { [weak self, weak pane] in
                              guard let self, let pane else { return }
                              self.window?.makeFirstResponder(pane.focusView)
                              self.paneDidBecomeActive(pane)
                          },
                          onClose: { [weak self, weak pane] in
                              guard let self, let pane else { return }
                              self.closePane(pane)
                          },
                          onDrag: { [weak self, weak pane] phase in
                              guard let self, let pane else { return }
                              self.paneDragged(pane, tab: nil, phase: phase)
                          }))
    }

    func paneRequestsClose(_ pane: PaneViewController) { closePane(pane) }

    func pane(_ pane: PaneViewController, requestsSplit edge: PaneLayout.Edge) { split(edge, of: pane) }
}

/// A pane or tab being dragged, and where it would land right now.
struct PaneDrag {
    let pane: PaneViewController
    let tab: Int?
    var target: MainWindowController.DropTarget?
    var monitor: Any?

    init(pane: PaneViewController, tab: Int?) {
        self.pane = pane
        self.tab = tab
    }
}
