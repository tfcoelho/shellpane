// Shellpane: a Mac file manager for your servers, over the system's own SSH.
//
//   swift run ShellpaneApp
//   SHELLPANE_SSH_CONFIG=/path/ssh_config swift run ShellpaneApp      use another ssh_config (dev / tests)
//   ShellpaneApp --snapshot out.png [--left PATH] [--right HOST|PATH] [--select ROW [--copy]] [--dark]
//                                   render the window to a PNG and quit (for visual checks)
//   ShellpaneApp --demo out.mp4 --left PATH --right HOST [--mark a,b,c] [--filter TEXT]
//                                   play the core flow and record it (scripts/demo-video.sh)

import AppKit
import ShellpaneCore
import SSHProcess
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        RemoteEditManager.cleanUpOldCopies()
        try? FileManager.default.removeItem(at: QuickLookCenter.cacheRoot)   // last session's Quick Look downloads
        _ = SettingsModel.shared   // applies bandwidth limits saved last time
        let args = CommandLine.arguments
        let scripted = ["--selftest", "--selftest-password", "--snapshot", "--demo", "--states"].contains(where: args.contains)
        let controller = MainWindowController(scripted: scripted)
        main = controller
        controller.window?.center()
        controller.showWindow(nil)
        if let active = controller.activePane { controller.window?.makeFirstResponder(active.focusView) }
        NSApp.activate(ignoringOtherApps: true)

        if args.contains("--selftest") {
            SelfTest.run(controller)
            return
        }
        if args.contains("--selftest-password") {
            SelfTest.runPassword(controller)
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(controller, to: args[i + 1], arguments: args)
        }
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            Demo.run(controller, to: args[i + 1], arguments: args)
        }
        if let i = args.firstIndex(of: "--states"), i + 1 < args.count {
            DemoStates.run(controller, to: args[i + 1], arguments: args)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        main?.savePanes()
        RemoteEditManager.shared.stopAll()
        ConnectionManager.shared.closeAll()
    }

    // Menu actions are routed to the main window.
    @objc func connect(_ sender: Any?) { main?.showConnectPrompt() }
    @objc func copyToOtherPane(_ sender: Any?) { main?.copyToOtherPane(sender) }
    @objc func moveToOtherPane(_ sender: Any?) { main?.moveToOtherPane(sender) }
    @objc func newFolder(_ sender: Any?) { main?.activePane?.newFolder() }
    @objc func renameSelection(_ sender: Any?) { main?.activePane?.renameSelected() }
    @objc func deleteSelection(_ sender: Any?) { main?.activePane?.deleteSelected() }
    @objc func copyPath(_ sender: Any?) { main?.activePane?.copyPath() }
    @objc func showSync(_ sender: Any?) { main?.showSync(sender) }
    @objc func openInTerminal(_ sender: Any?) { main?.openInTerminal(sender) }
    @objc func newTab(_ sender: Any?) { main?.newTab(sender) }
    @objc func toggleInspector(_ sender: Any?) { main?.toggleInspector(sender) }
    @objc func exportServers(_ sender: Any?) { main?.exportServers(sender) }
    @objc func importServers(_ sender: Any?) { main?.importServers(sender) }
    @objc func toggleFilter(_ sender: Any?) { main?.toggleFilter(sender) }

    private var settingsWindow: NSWindow?
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: SettingsModel.shared)))
            w.title = "Shellpane Settings"
            w.styleMask = [.titled, .closable]
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func viewAsList(_ sender: Any?) { main?.viewAsList(sender) }
    @objc func viewAsColumns(_ sender: Any?) { main?.viewAsColumns(sender) }
    @objc func viewAsIcons(_ sender: Any?) { main?.viewAsIcons(sender) }
    @objc func makeBigger(_ sender: Any?) { main?.activePane?.zoomIn() }
    @objc func makeSmaller(_ sender: Any?) { main?.activePane?.zoomOut() }
    @objc func actualSize(_ sender: Any?) { main?.activePane?.resetZoom() }
    @objc func splitRight(_ sender: Any?) { main?.splitRight(sender) }
    @objc func splitDown(_ sender: Any?) { main?.splitDown(sender) }
    @objc func closePane(_ sender: Any?) { main?.closeActivePane(sender) }
    @objc func focusPaneLeft(_ sender: Any?) { main?.focusPane(.left) }
    @objc func focusPaneRight(_ sender: Any?) { main?.focusPane(.right) }
    @objc func focusPaneUp(_ sender: Any?) { main?.focusPane(.top) }
    @objc func focusPaneDown(_ sender: Any?) { main?.focusPane(.bottom) }
    @objc func applyLayout(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String, let preset = PaneLayout.Preset(rawValue: name) { main?.apply(preset) }
    }
    @objc func closeTabOrWindow(_ sender: Any?) { main?.closeTabOrWindow(sender) }
    @objc func nextTab(_ sender: Any?) { main?.nextTab(sender) }
    @objc func previousTab(_ sender: Any?) { main?.previousTab(sender) }
    @objc func reload(_ sender: Any?) { main?.reloadActive(sender) }
    @objc func toggleHidden(_ sender: Any?) { main?.toggleHidden(sender) }
    @objc func goUp(_ sender: Any?) { main?.goUp(sender) }
    @objc func goBack(_ sender: Any?) { main?.goBack(sender) }
    @objc func goForward(_ sender: Any?) { main?.goForward(sender) }
    @objc func openSelection(_ sender: Any?) { main?.openSelection(sender) }
    @objc func showActivity(_ sender: Any?) { main?.showActivity(sender) }
    @objc func goToPath(_ sender: Any?) { main?.goToPath(sender) }
    @objc func toggleBookmark(_ sender: Any?) { main?.toggleBookmark(sender) }
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            top.submenu = sub
            menu.addItem(top)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let f5 = String(UnicodeScalar(NSF5FunctionKey)!)
        let f6 = String(UnicodeScalar(NSF6FunctionKey)!)
        // ⌘+ is ⌘= without Shift on most keyboards: a hidden twin catches that one.
        let biggerWithoutShift = item("Make Bigger", #selector(AppDelegate.makeBigger(_:)), "=")
        biggerWithoutShift.isHidden = true
        biggerWithoutShift.allowsKeyEquivalentWhenHidden = true

        submenu("Shellpane", [
            item("About Shellpane", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide Shellpane", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Shellpane", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("Connect to Server…", #selector(AppDelegate.connect(_:)), "k"),
            .separator(),
            item("New Folder…", #selector(AppDelegate.newFolder(_:)), "n", [.command, .shift]),
            item("Open", #selector(AppDelegate.openSelection(_:)), down),
            item("Rename…", #selector(AppDelegate.renameSelection(_:))),  // Return, handled by the pane: a menu key would steal it from text fields
            .separator(),
            item("Copy to Other Pane", #selector(AppDelegate.copyToOtherPane(_:)), f5, []),
            item("Move to Other Pane", #selector(AppDelegate.moveToOtherPane(_:)), f6, []),
            item("Copy Path", #selector(AppDelegate.copyPath(_:)), "c", [.command, .option]),
            item("Sync Folders…", #selector(AppDelegate.showSync(_:)), "y", [.command, .option]),
            item("Open in Terminal", #selector(AppDelegate.openInTerminal(_:)), "t", [.command, .option]),
            .separator(),
            item("Delete…", #selector(AppDelegate.deleteSelection(_:))),  // ⌘⌫, handled by the pane for the same reason
            .separator(),
            item("New Tab", #selector(AppDelegate.newTab(_:)), "t"),
            item("Close Tab or Pane", #selector(AppDelegate.closeTabOrWindow(_:)), "w"),
            .separator(),
            item("Export Servers…", #selector(AppDelegate.exportServers(_:))),
            item("Import Servers…", #selector(AppDelegate.importServers(_:))),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("View", [
            item("as List", #selector(AppDelegate.viewAsList(_:)), "1"),
            item("as Icons", #selector(AppDelegate.viewAsIcons(_:)), "2"),
            item("as Columns", #selector(AppDelegate.viewAsColumns(_:)), "3"),
            .separator(),
            item("Make Bigger", #selector(AppDelegate.makeBigger(_:)), "+"),
            biggerWithoutShift,
            item("Make Smaller", #selector(AppDelegate.makeSmaller(_:)), "-"),
            item("Actual Size", #selector(AppDelegate.actualSize(_:)), "0"),
            .separator(),
            item("Show Hidden Files", #selector(AppDelegate.toggleHidden(_:)), ".", [.command, .shift]),
            item("Filter", #selector(AppDelegate.toggleFilter(_:)), "f", [.command, .option]),
            item("Reload", #selector(AppDelegate.reload(_:)), "r"),
            item("Show Activity", #selector(AppDelegate.showActivity(_:)), "a", [.command, .option]),
            item("Show Info", #selector(AppDelegate.toggleInspector(_:)), "i", [.command, .option]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
        ])
        let layoutItem = item("Layout", nil)
        let layoutMenu = NSMenu(title: "Layout")
        for preset in PaneLayout.Preset.allCases {
            let i = item(preset.title, #selector(AppDelegate.applyLayout(_:)))
            i.representedObject = preset.rawValue
            layoutMenu.addItem(i)
        }
        layoutItem.submenu = layoutMenu
        submenu("Panes", [
            item("New Pane on the Right", #selector(AppDelegate.splitRight(_:)), "\\"),
            item("New Pane Below", #selector(AppDelegate.splitDown(_:)), "\\", [.command, .shift]),
            item("Close Pane", #selector(AppDelegate.closePane(_:))),
            .separator(),
            layoutItem,
            .separator(),
            item("Pane on the Left", #selector(AppDelegate.focusPaneLeft(_:)), leftArrow, [.command, .option]),
            item("Pane on the Right", #selector(AppDelegate.focusPaneRight(_:)), rightArrow, [.command, .option]),
            item("Pane Above", #selector(AppDelegate.focusPaneUp(_:)), up, [.command, .option]),
            item("Pane Below", #selector(AppDelegate.focusPaneDown(_:)), down, [.command, .option]),
        ])
        submenu("Go", [
            item("Back", #selector(AppDelegate.goBack(_:)), "["),
            item("Forward", #selector(AppDelegate.goForward(_:)), "]"),
            item("Enclosing Folder", #selector(AppDelegate.goUp(_:)), up),
            .separator(),
            item("Go to Path…", #selector(AppDelegate.goToPath(_:)), "g", [.command, .shift]),
            item("Add to Favorite Folders", #selector(AppDelegate.toggleBookmark(_:)), "t", [.command, .control]),
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Show Next Tab", #selector(AppDelegate.nextTab(_:)), "\t", .control))
        windowMenu.addItem(item("Show Previous Tab", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift]))
        let windowTop = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowTop.submenu = windowMenu
        menu.addItem(windowTop)
        NSApp.windowsMenu = windowMenu
        return menu
    }
}

/// Renders the real window (with real data) to a PNG for visual checks.
@MainActor
enum Snapshot {
    static func run(_ controller: MainWindowController, to path: String, arguments args: [String]) {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        // Start both panes somewhere neutral so a snapshot never shows the person's own folders.
        // --left / --right take a local path ("/…") or a server (favorite name or ssh_config host).
        let neutral = [value("--left"), value("--right")].compactMap { $0 }.first { $0.hasPrefix("/") } ?? "/"
        // --layout NAME: arrange the panes with a preset first (all at the neutral folder)
        // --start-page: the last pane on its start page. --no-panes: no panes at all.
        // --paths a,b,c: put the panes in these folders, in reading order, after everything else
        if let name = value("--layout"), let preset = PaneLayout.Preset(rawValue: name) { controller.apply(preset) }
        for pane in controller.panes { pane.navigate(to: .local(neutral)) }
        controller.left.navigate(to: .local(neutral))
        controller.right.navigate(to: .local(neutral))
        if let l = value("--left"), !l.hasPrefix("/") {
            controller.paneDidBecomeActive(controller.left)
            if let fav = controller.sidebarModel.favorites.first(where: { $0.name == l }) {
                controller.connect(fav)
            } else {
                controller.connect(to: SSHTarget(host: l), key: "alias:" + l)
            }
        }
        if let r = value("--right") {
            if r.hasPrefix("/") {
                controller.right.navigate(to: .local(r))
            } else {
                controller.paneDidBecomeActive(controller.right)
                if let fav = controller.sidebarModel.favorites.first(where: { $0.name == r }) {
                    controller.connect(fav)
                } else {
                    controller.connect(to: SSHTarget(host: r), key: "alias:" + r)
                }
            }
        }
        // Scripted checks against a demo server:
        //   --select NAME        select a row in the right pane by name
        //   --copy | --move      then copy / move it to the left pane
        //   --edit               then open it for editing (remote file)
        //   --kill-ssh           kill the right pane's ssh process, then reload (tests auto-reconnect)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let pane = controller.right
            if let name = value("--select"), let i = pane.entries.firstIndex(where: { $0.name == name }) {
                pane.tableView.selectRowIndexes([i], byExtendingSelection: false)
                controller.paneDidBecomeActive(pane)
                if args.contains("--copy") { controller.transferToOtherPane(.copy) }
                if args.contains("--move") { controller.transferToOtherPane(.move) }
                if args.contains("--edit") { pane.editRemote(pane.entries[i], with: URL(fileURLWithPath: "/System/Applications/TextEdit.app")) }
            }
            // --mark a,b,c: Commander-mark these names in the right pane, cursor after the last one
            if let names = value("--mark")?.split(separator: ",").map(String.init) {
                controller.paneDidBecomeActive(pane)
                pane.view.window?.makeFirstResponder(pane.tableView)
                let rows = names.compactMap { n in pane.entries.firstIndex { $0.name == n } }.sorted()
                for r in rows {
                    pane.tableView.setCursor(r)
                    pane.tableView.toggleMarkAndAdvance()
                }
            }
            // --expand a,b: open these folders in place in the right pane's list
            for name in value("--expand")?.split(separator: ",").map(String.init) ?? [] {
                if let i = pane.entries.firstIndex(where: { $0.name == name }) { pane.setExpanded(true, row: i) }
                try? await Task.sleep(for: .milliseconds(400))
            }
            // --tag NAME: show a Finder tag's files in the right pane
            if let name = value("--tag") { pane.showTag(FinderTag(name: name, colour: FinderTags.colour(of: name))) }
            // --edit-path: show the right pane's path field
            if args.contains("--edit-path") { pane.beginEditingPath() }
            for (pane, path) in zip(controller.panes, value("--paths")?.split(separator: ",").map(String.init) ?? []) {
                pane.navigate(to: .local(path))
            }
            if value("--paths") != nil { try? await Task.sleep(for: .milliseconds(400)) }
            if let name = value("--select-first"), let first = controller.panes.first, let i = first.entries.firstIndex(where: { $0.name == name }) {
                first.tableView.selectRowIndexes([i], byExtendingSelection: false)
                controller.window?.makeFirstResponder(first.tableView)
            }
            if args.contains("--start-page") { controller.panes.last?.setShowsStart(true) }
            if args.contains("--no-panes") { controller.panes.forEach(controller.closePane) }
            // --picker: choose a destination for what's selected (with --select)
            if args.contains("--picker") { controller.transfer(.copy, alwaysAsk: true) }
            if let i = value("--highlight").flatMap(Int.init) { controller.picker?.highlight(i) }
            // --drag-at x,y: dragging the first pane, the pointer at this fraction of the pane area
            if let at = value("--drag-at")?.split(separator: ",").compactMap({ Double($0) }), at.count == 2, let first = controller.panes.first {
                let b = controller.area.visibleBounds
                controller.beginDrag(first, tab: nil)
                controller.updateDrag(at: NSPoint(x: b.minX + b.width * at[0], y: b.minY + b.height * at[1]))
            }
            // --view icons|columns: switch the right pane's view
            if let mode = value("--view") {
                controller.paneDidBecomeActive(pane)
                if mode == "icons" { controller.viewAsIcons(nil) }
                if mode == "columns" { controller.viewAsColumns(nil) }
            }
            if args.contains("--kill-ssh"), let session = pane.location.session {
                kill(session.client.transport.processIdentifier, SIGKILL)
                try? await Task.sleep(for: .milliseconds(500))
                pane.reload()
            }
        }
        if let sheet = value("--sheet") {
            if sheet == "connect" {
                controller.showServerForm(.connect)
            } else if sheet.hasPrefix("edit:"), let fav = controller.sidebarModel.favorites.first(where: { $0.name == String(sheet.dropFirst(5)) }) {
                controller.showServerForm(.edit(fav))
            } else if sheet.hasPrefix("folder:"), let b = controller.sidebarModel.bookmarks.first(where: { $0.name == String(sheet.dropFirst(7)) }) {
                controller.showBookmarkForm(b)
            } else if sheet.hasPrefix("host:") {
                controller.showAppearanceForm(controller.sidebarModel.hostItem(String(sheet.dropFirst(5))))
            } else if sheet.hasPrefix("group:"), let g = controller.sidebarModel.groups.first(where: { $0.name == String(sheet.dropFirst(6)) }) {
                controller.showGroupForm(g)
            } else if sheet.hasPrefix("synclet:"), let s = controller.sidebarModel.synclets.first(where: { $0.name == String(sheet.dropFirst(8)) }) {
                controller.showSyncletForm(s)
            } else if sheet.hasPrefix("place:") {
                let path = String(sheet.dropFirst(6))
                controller.showAppearanceForm(controller.sidebarModel.placeItem(.init(id: path, title: (path as NSString).lastPathComponent, symbol: "folder", path: path)))
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(value("--delay") ?? "3") ?? 3))
            if args.contains("--dark") { controller.window?.appearance = NSAppearance(named: .darkAqua) }
            if args.contains("--light") { controller.window?.appearance = NSAppearance(named: .aqua) }
            try? await Task.sleep(for: .milliseconds(300))
            // With --sheet, capture the sheet window instead of the main window.
            let target = value("--sheet") != nil ? (controller.window?.attachedSheet ?? controller.window) : controller.window
            guard let frameView = target?.contentView?.superview else { exit(1) }
            frameView.layoutSubtreeIfNeeded()
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(1) }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            // The picker is its own window over this one.
            if let surface = controller.picker?.surface, let top = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
                surface.cacheDisplay(in: surface.bounds, to: top)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                top.draw(in: frameView.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            let ok = rep.representation(using: .png, properties: [:]).map {
                FileManager.default.createFile(atPath: path, contents: $0)
            } ?? false
            print(ok ? "wrote \(path)" : "snapshot failed")
            ConnectionManager.shared.closeAll()
            exit(ok ? 0 : 1)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
