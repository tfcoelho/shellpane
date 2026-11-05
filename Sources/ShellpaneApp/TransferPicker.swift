import AppKit
import ShellpaneUI
import SwiftUI

/// Choosing a destination: the app dims and the panes that can take the files stay lit, like choosing a window
/// to record. They keep their exact size and place: grown, they'd overlap each other and be cut off at the
/// window's edge. Click one or press its number; ↑↓←→ and Return work too, Esc or a click elsewhere cancels.
/// The panes are pictures while this is up. They're live again a moment later.
@MainActor
final class TransferPicker: NSObject {
    struct Option {
        let pane: PaneViewController
        /// Where things would land, or what the choice means.
        let place: String
        /// Why this pane can't be chosen; nil if it can.
        let problem: String?
    }

    private final class PickerWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let parent: NSWindow
    private let source: PaneViewController?
    private let sourceText: String?
    private let actionText: String
    private let options: [Option]
    private let onChoose: (PaneViewController) -> Void
    private let onOpenPane: (() -> Void)?
    private let onDismiss: () -> Void
    private let overlay: PickerWindow
    let surface = PickerSurface()
    private var cards: [PickerCard] = []
    private var highlighted: Int? { didSet { if highlighted != oldValue { refreshCards() } } }
    private var observer: NSObjectProtocol?
    private(set) var isShown = false

    /// The panes that can be chosen, in reading order; their position plus one is the key to press.
    var choices: [PaneViewController] { cards.map(\.option.pane) }

    init(parent: NSWindow, source: PaneViewController?, sourceText: String?, actionText: String, options: [Option],
         onChoose: @escaping (PaneViewController) -> Void, onOpenPane: (() -> Void)?, onDismiss: @escaping () -> Void) {
        self.parent = parent
        self.source = source
        self.sourceText = sourceText
        self.actionText = actionText
        self.options = options
        self.onChoose = onChoose
        self.onOpenPane = onOpenPane
        self.onDismiss = onDismiss
        overlay = PickerWindow(contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.isReleasedWhenClosed = false
        overlay.appearance = parent.effectiveAppearance
        overlay.contentView = surface
    }

    func show() {
        isShown = true
        parent.contentView?.layoutSubtreeIfNeeded()
        surface.picker = self
        surface.frame = NSRect(origin: .zero, size: parent.frame.size)
        let dim = surface.dim
        dim.frame = surface.bounds
        dim.autoresizingMask = [.width, .height]
        surface.addSubview(dim)
        dim.alphaValue = 0

        var count = 0
        for option in options {
            let rect = option.pane.view.convert(option.pane.view.safeAreaRect, to: nil)
            if option.problem == nil, let image = Self.picture(of: option.pane.view) {
                count += 1
                let card = PickerCard(option: option, number: count, picture: image, picker: self)
                card.frame = rect
                surface.addSubview(card)
                cards.append(card)
            } else if let problem = option.problem {
                addNote(problem, muted: true, centeredIn: rect)
            }
        }
        if let source, let sourceText {
            addNote(sourceText, muted: false, centeredIn: source.view.convert(source.view.safeAreaRect, to: nil))
        }
        if cards.isEmpty {
            addNothingToChoose()
        } else {
            addHint()
        }
        refreshCards()
        parent.addChildWindow(overlay, ordered: .above)
        overlay.setFrame(parent.frame, display: true)
        overlay.makeKeyAndOrderFront(nil)
        overlay.makeFirstResponder(surface)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dim.animator().alphaValue = 1
        }
    }

    /// Below the toolbar: the part of a pane you can see.
    private static func picture(of view: NSView) -> NSImage? {
        let visible = view.safeAreaRect
        guard let rep = view.bitmapImageRepForCachingDisplay(in: visible) else { return nil }
        view.cacheDisplay(in: visible, to: rep)
        let image = NSImage(size: visible.size)
        image.addRepresentation(rep)
        return image
    }

    private func addNote(_ text: String, muted: Bool, centeredIn rect: NSRect) {
        let note = PassiveHostingView(rootView: AnyView(
            Text(verbatim: text)
                .font(.callout.weight(.medium))
                .foregroundStyle(muted ? Color.white.opacity(0.6) : Color.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Space.s12)
                .padding(.vertical, Tokens.Space.s6)
                .background(Color.black.opacity(0.45), in: Capsule())
                .frame(maxWidth: max(rect.width - 24, 80))
        ))
        let size = note.fittingSize
        note.frame = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        surface.addSubview(note)
    }

    private func addHint() {
        let hint = PassiveHostingView(rootView: AnyView(
            Text(verbatim: cards.count > 1 ? "Click a pane or press its number. Esc cancels." : "Click the pane or press 1. Esc cancels.")
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, Tokens.Space.s12)
                .padding(.vertical, Tokens.Space.s6)
                .background(Color.black.opacity(0.55), in: Capsule())
        ))
        let size = hint.fittingSize
        hint.frame = NSRect(x: (surface.bounds.width - size.width) / 2, y: 16, width: size.width, height: size.height)
        surface.addSubview(hint)
    }

    /// One pane open, or none that can take the files: say so, and offer a pane if that's the way out.
    private func addNothingToChoose() {
        let open = onOpenPane
        let card = NSHostingView(rootView: AnyView(
            VStack(spacing: Tokens.Space.s12) {
                Text(verbatim: open == nil ? "No pane can take these right now" : "There's no other pane to send these to")
                    .font(.body.weight(.semibold))
                Text(verbatim: open == nil ? "Open a folder in one of the other panes, then try again."
                                           : "Open a second pane, choose where to go, then press F5 again. Your selection stays.")
                    .font(.callout)
                    .foregroundStyle(Tokens.Colors.textMuted)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Cancel") { [weak self] in self?.cancel() }
                    if open != nil {
                        Button("Open a Pane") { [weak self] in
                            self?.dismiss()
                            open?()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(Tokens.Space.s20)
            .frame(width: 320)
            .background(Tokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        ))
        let size = card.fittingSize
        card.frame = NSRect(x: (surface.bounds.width - size.width) / 2, y: (surface.bounds.height - size.height) / 2, width: size.width, height: size.height)
        surface.addSubview(card)
    }

    private func refreshCards() {
        for (i, card) in cards.enumerated() {
            card.setHighlighted(i == highlighted, action: actionText)
        }
    }

    func hover(_ card: PickerCard, inside: Bool) {
        guard let i = cards.firstIndex(where: { $0 === card }) else { return }
        if inside { highlighted = i } else if highlighted == i { highlighted = nil }
    }

    /// Highlights a choice as hovering would.
    func highlight(_ index: Int) { highlighted = index }

    func choose(_ card: PickerCard) {
        guard let i = cards.firstIndex(where: { $0 === card }) else { return }
        choose(at: i)
    }

    func choose(at index: Int) {
        guard isShown, cards.indices.contains(index) else { NSSound.beep(); return }
        let chosen = cards[index]
        let pane = chosen.option.pane
        // The others go first, then everything fades.
        let others = cards.filter { $0 !== chosen }
        isShown = false
        removeObserver()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            surface.animator().alphaValue = 0
            others.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [overlay, parent] in
            MainActor.assumeIsolated {
                parent.removeChildWindow(overlay)
                overlay.orderOut(nil)
            }
        })
        parent.makeKey()
        onDismiss()
        onChoose(pane)
    }

    func cancel() {
        guard isShown else { return }
        dismiss()
    }

    private func dismiss() {
        isShown = false
        removeObserver()
        parent.removeChildWindow(overlay)
        overlay.orderOut(nil)
        parent.makeKey()
        onDismiss()
    }

    private func removeObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Returns false if the key isn't for the picker.
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: cancel()                                       // Esc
        case 36, 76:                                            // Return, Enter
            if let highlighted { choose(at: highlighted) } else if cards.count == 1 { choose(at: 0) } else { NSSound.beep() }
        case 124, 125: moveHighlight(1)                         // → ↓
        case 123, 126: moveHighlight(-1)                        // ← ↑
        default:
            guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit >= 1 else { return false }
            choose(at: digit - 1)
        }
        return true
    }

    private func moveHighlight(_ step: Int) {
        guard !cards.isEmpty else { return }
        highlighted = ((highlighted ?? (step > 0 ? -1 : 0)) + step + cards.count) % cards.count
    }
}

/// A hosted label that lets clicks through to the dimmed background.
private final class PassiveHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The dim layer. A click on it, or anywhere that isn't a card, cancels.
final class PickerSurface: NSView {
    weak var picker: TransferPicker?
    let dim = DimView()

    final class DimView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.55).setFill()
            bounds.intersection(dirtyRect).fill()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { picker?.cancel() }
    override func keyDown(with event: NSEvent) {
        if picker?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

/// A pane that can be chosen: its picture, with its number and where things would land. Highlighting brightens
/// it and draws inside its edges, so it never covers a neighbour or runs out of the window.
final class PickerCard: NSView {
    let option: TransferPicker.Option
    private let number: Int
    private weak var picker: TransferPicker?
    private let picture = NSImageView()
    /// Quietens the panes that aren't highlighted, and tints the one that is.
    private let wash = NSView()
    private let label = PassiveHostingView(rootView: AnyView(EmptyView()))
    private var highlighted = false

    init(option: TransferPicker.Option, number: Int, picture image: NSImage, picker: TransferPicker) {
        self.option = option
        self.number = number
        self.picker = picker
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.controlAccentColor.cgColor
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 14
        layer?.shadowOffset = .zero
        picture.image = image
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        picture.layer?.cornerRadius = Tokens.Radius.md
        picture.layer?.masksToBounds = true
        picture.autoresizingMask = [.width, .height]
        addSubview(picture)
        wash.wantsLayer = true
        wash.layer?.cornerRadius = Tokens.Radius.md
        wash.autoresizingMask = [.width, .height]
        addSubview(wash)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pane \(number): \(option.place)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        picture.frame = bounds
        wash.frame = bounds
        positionLabel()
    }

    private func positionLabel() {
        let size = label.fittingSize
        label.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    func setHighlighted(_ on: Bool, action: String) {
        highlighted = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            // Borders are drawn inside the bounds, so the pane stays exactly its own size.
            wash.layer?.borderWidth = on ? 3 : 1
            wash.layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.25)).cgColor
            wash.layer?.backgroundColor = (on ? NSColor.controlAccentColor.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.18)).cgColor
            layer?.shadowOpacity = on ? 0.7 : 0
            layer?.zPosition = on ? 1 : 0   // the glow falls on its neighbours, not under them
        }
        let number = number, place = option.place
        let width = max(bounds.width - 32, 160)
        label.rootView = AnyView(
            VStack(spacing: Tokens.Space.s6) {
                Text(verbatim: "\(number)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(on ? Color.accentColor : Color.black.opacity(0.7), in: Circle())
                Text(verbatim: place)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                if on {
                    Text(verbatim: action).font(.callout).foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(Tokens.Space.s12)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .frame(maxWidth: width)
        )
        positionLabel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { picker?.hover(self, inside: true) }
    override func mouseExited(with event: NSEvent) { picker?.hover(self, inside: false) }
    override func mouseDown(with event: NSEvent) { picker?.choose(self) }
}
