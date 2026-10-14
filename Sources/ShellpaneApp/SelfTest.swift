import AppKit
import Quartz
import ShellpaneCore
import SFTPKit
import SSHProcess
import TransferKit

/// `ShellpaneApp --selftest`: runs the app's own flows against a demo server through the real code paths
/// (drop validation and acceptance, file promises, the code behind each dialog's OK button, editing,
/// reconnecting) and prints PASS / FAIL per case. Driven by e2e/run.sh, which sets up the server.
/// What it can't do is move a real mouse: the drag gesture itself stays on the manual list.
///
/// Env: SHELLPANE_SELFTEST_LOCAL = a scratch local folder; the right pane connects to ssh_config host "web-1".
@MainActor
enum SelfTest {
    static var passed = 0
    static var failed: [String] = []
    static var skipped: [String] = []
    /// Whether the last real event went to a key window. macOS only delivers keys and first clicks to the key
    /// window; when someone else's app is in front, Shellpane can't be made key and those cases can't run.
    static var lastEventWindowWasKey = true

    /// PASS / FAIL as usual, but SKIP (not counted) when the event couldn't reach a key window.
    static func checkEvent(_ id: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok && !lastEventWindowWasKey {
            skip(id, "Shellpane's window couldn't be made key; someone was using another app")
        } else {
            check(id, ok, detail())
        }
    }

    static func skip(_ id: String, _ why: String) {
        skipped.append(id)
        print("SKIP \(id) (\(why))")
        fflush(stdout)
    }

    static func check(_ id: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            print("PASS \(id)")
        } else {
            failed.append(id)
            print("FAIL \(id) \(detail())")
        }
        fflush(stdout)
    }

    static func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    static func lastTransferFinished() -> Bool {
        guard let item = TransferCenter.shared.items.last else { return false }
        switch item.status {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    static func startedTransfer(_ before: Int) async -> TransferItem? {
        guard await waitUntil(5, { TransferCenter.shared.items.count > before }) else { return nil }
        _ = await waitUntil(20, lastTransferFinished)
        return TransferCenter.shared.items.last
    }

    static func data(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    /// A real double-click: mouse down/up events delivered through the window to the table.
    static func doubleClick(_ table: NSTableView, row: Int) {
        guard let window = table.window else { return }
        // A person double-clicks in a focused window. If another app is in front, the first click would only
        // bring Shellpane forward (that's macOS, not Shellpane), so make the window key first.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        lastEventWindowWasKey = window.isKeyWindow
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
        if ProcessInfo.processInfo.environment["SHELLPANE_SELFTEST_DEBUG"] != nil, let frame = window.contentView?.superview {
            var v: NSView? = frame.hitTest(frame.convert(point, from: nil))
            var chain: [String] = []
            while let x = v, chain.count < 8 { chain.append(String(describing: type(of: x)) + (x.isHidden ? "(hidden)" : "")); v = x.superview }
            print("DEBUG hit at row \(row): " + chain.joined(separator: " < "))
        }
        for clicks in [1, 2] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: clicks, pressure: 1) else { continue }
                if type == .leftMouseDown {
                    // NSTableView tracks the mouse until mouse-up: queue the up first so tracking ends.
                    if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: e.timestamp,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: clicks, pressure: 0) {
                        NSApp.postEvent(up, atStart: false)
                    }
                    window.sendEvent(e)
                }
            }
        }
    }

    /// A real single click in `view` at `rect` (view coordinates).
    static func click(_ view: NSView, rect: NSRect) {
        guard let window = view.window else { return }
        let point = view.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: down.timestamp,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    /// A key press through NSApp, so menu key equivalents (⌘[) get their chance first, as with a real keyboard.
    static func keyThroughApp(code: UInt16, chars: String, mods: NSEvent.ModifierFlags) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible),
              let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(e)
    }

    static func key(_ view: NSView, code: UInt16, chars: String, mods: NSEvent.ModifierFlags) {
        if let w = view.window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            lastEventWindowWasKey = w.isKeyWindow
        }
        guard let window = view.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                                context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                                isARepeat: false, keyCode: code) else { return }
        window.sendEvent(e)
    }

    /// Saves a window to $SHELLPANE_SELFTEST_SCREENS (demo data only) for the build log and visual checks.
    static func screenshot(_ window: NSWindow?, _ name: String) async {
        guard let dir = ProcessInfo.processInfo.environment["SHELLPANE_SELFTEST_SCREENS"], !dir.isEmpty,
              let frame = window?.contentView?.superview else { return }
        try? await Task.sleep(for: .milliseconds(600))
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
    }

    static func childProcesses(named name: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(getpid()), "-x", name]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).count
    }

    /// `ShellpaneApp --selftest-password`, driven by e2e/password.sh against a password-only test server.
    static func runPassword(_ c: MainWindowController) {
        Task { @MainActor in
            await passwordCases(c)
            print("\nSELFTEST \(passed) passed, \(failed.count) failed" + (failed.isEmpty ? "" : ": " + failed.joined(separator: ", ")))
            fflush(stdout)
            ConnectionManager.shared.closeAll()
            exit(failed.isEmpty ? 0 : 1)
        }
    }

    static func passwordCases(_ c: MainWindowController) async {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["SHELLPANE_PW_ROOT"], let password = env["SHELLPANE_PW_PASSWORD"] else { check("setup", false); return }
        var answers: [String] = []      // what the "person" types, in order
        Prompter.testAnswer = { request, _ in
            switch request.kind {
            case .hostKey: return "yes"
            case .secret: return answers.isEmpty ? nil : answers.removeFirst()
            default: return nil
            }
        }
        let fav = ShellpaneCore.Favorite(name: "Password box", sshAlias: "pwbox", auth: .password, keychainRef: UUID().uuidString)
        try? ConnectionManager.shared.save(fav)
        c.sidebarModel.reloadFavorites()

        // F01-N4 a wrong password in the form: asked again, the right one works, the wrong one is never saved
        answers = [password]
        Prompter.testLog = []
        do {
            let s = try await ConnectionManager.shared.connect(fav, typedPassword: "wrong guess", savePassword: true)
            let listing = try await s.client.list(RemotePath.join(root, "site")).map(\.name)
            let secretPrompts = Prompter.testLog.filter { $0.kind == .secret }.count
            // The typed one is tried first by Shellpane itself; the person is asked exactly once more.
            check("F01-N4 wrong typed password: asked again, then connected", listing == ["hello.txt"] && secretPrompts == 1,
                  "listing \(listing), password prompts \(secretPrompts)")
            let stored = try? ConnectionManager.shared.secrets.secret(for: fav.keychainRef!)
            check("F01-N4 the password that worked is saved, the wrong one isn't", stored == password, "stored \(stored == nil ? "nothing" : "something else")")
            check("F01-H6 first contact asked about the host key", Prompter.testLog.contains { $0.kind == .hostKey })
            ConnectionManager.shared.disconnect(fav.id)
        } catch {
            check("F01-N4 wrong typed password: asked again, then connected", false, error.localizedDescription)
        }

        // F02-H1 reconnect: the saved password is used, nobody is asked
        answers = []
        Prompter.testLog = []
        do {
            let s = try await ConnectionManager.shared.connect(fav)
            _ = try await s.client.realpath(".")
            check("F02-H1 reconnect with the saved password, no prompt", !Prompter.testLog.contains { $0.kind == .secret })
            ConnectionManager.shared.disconnect(fav.id)
        } catch {
            check("F02-H1 reconnect with the saved password, no prompt", false, error.localizedDescription)
        }

        // F02-E3 the saved password changed on the server: asked once, told why, the new one replaces it
        try? ConnectionManager.shared.secrets.setSecret("old password", for: fav.keychainRef!, label: "Shellpane e2e")
        answers = [password]
        Prompter.testLog = []
        do {
            _ = try await ConnectionManager.shared.connect(fav)
            let stored = try? ConnectionManager.shared.secrets.secret(for: fav.keychainRef!)
            check("F02-E3 a stale saved password is replaced by the one that works", stored == password)
            ConnectionManager.shared.disconnect(fav.id)
        } catch {
            check("F02-E3 a stale saved password is replaced by the one that works", false, error.localizedDescription)
        }

        // F01-N1 every password wrong: a plain message, nothing saved
        try? ConnectionManager.shared.secrets.deleteSecret(for: fav.keychainRef!)
        answers = ["nope", "still nope", "nope again"]
        do {
            _ = try await ConnectionManager.shared.connect(fav, typedPassword: "nope", savePassword: true)
            check("F01-N1 all wrong: refused", false, "it connected")
        } catch {
            let saved = try? ConnectionManager.shared.secrets.secret(for: fav.keychainRef!)
            check("F01-N1 all wrong: a plain message, nothing saved",
                  error.localizedDescription.contains("didn't accept the login") && saved == nil, error.localizedDescription)
        }
        Prompter.testAnswer = nil
    }

    static func run(_ c: MainWindowController) {
        Task { @MainActor in
            await runAll(c)
            print("\nSELFTEST \(passed) passed, \(failed.count) failed" + (skipped.isEmpty ? "" : ", \(skipped.count) skipped")
                  + (failed.isEmpty ? "" : ": " + failed.joined(separator: ", ")))
            fflush(stdout)
            RemoteEditManager.shared.stopAll()
            ConnectionManager.shared.closeAll()
            exit(failed.isEmpty ? 0 : 1)
        }
    }

    // swiftlint:disable:next function_body_length
    static func runAll(_ c: MainWindowController) async {
        guard let localRoot = ProcessInfo.processInfo.environment["SHELLPANE_SELFTEST_LOCAL"] else {
            check("setup", false, "SHELLPANE_SELFTEST_LOCAL not set")
            return
        }
        let left = c.left, right = c.right
        left.navigate(to: .local(localRoot))
        c.paneDidBecomeActive(right)
        // F01-E1 double-click: two connects in a row must open one connection, not two
        c.connect(to: SSHTarget(host: "web-1"), key: "alias:web-1")
        c.connect(to: SSHTarget(host: "web-1"), key: "alias:web-1")

        // F01-H1 connect through ssh_config and list the home folder
        let connected = await waitUntil(15) { right.location.session != nil && right.entries.contains { $0.name == "index.html" } }
        check("F01-H1 connect via ssh_config alias and list", connected,
              "pane at \(right.location.path), \(right.entries.count) entries, session \(right.location.session == nil ? "none" : "open")")
        guard connected, let session = right.location.session else { return }
        try? await Task.sleep(for: .milliseconds(500))
        let sshCount = childProcesses(named: "ssh")
        check("F01-E1 double-click opens one connection", sshCount == 1, "ssh processes: \(sshCount)")

        // BUG-004: a saved favorite for the same server shows as connected and reuses the open connection
        let saved = ShellpaneCore.Favorite(name: "Web 1 (saved)", sshAlias: "web-1")
        try? ConnectionManager.shared.save(saved)
        c.sidebarModel.reloadFavorites()
        c.connect(to: SSHTarget(host: "web-1"), key: "alias:web-1")
        _ = await waitUntil(5) { c.sidebarModel.connected[saved.id] != nil }
        check("BUG-004 the matching favorite's dot shows connected", c.sidebarModel.connected[saved.id] != nil)
        let reused = try? await ConnectionManager.shared.connect(saved)
        check("BUG-004 clicking the favorite reuses the open connection", reused === session && childProcesses(named: "ssh") == 1,
              "ssh processes: \(childProcesses(named: "ssh"))")
        let remoteRoot = right.location.path
        func r(_ name: String) -> String { RemotePath.join(remoteRoot, name) }
        func l(_ name: String) -> String { RemotePath.join(localRoot, name) }
        _ = await waitUntil { !left.entries.isEmpty }
        TransferCenter.shared.testResolver = { _ in .init(.skip) }

        // F01-H5 favorite groups: create, move a server in, the sidebar groups it; deleting keeps the server
        if let group = try? ConnectionManager.shared.groups.create("Clients") {
            c.sidebarModel.onMoveFavorite(saved, group.id)
            let grouped = c.sidebarModel.favorites(in: group).map(\.id) == [saved.id] && !c.sidebarModel.ungrouped.contains { $0.id == saved.id }
            check("F01-H5 a server moves into a group in the sidebar", grouped)
            await screenshot(c.window, "S02-groups.png")
            c.sidebarModel.onDeleteGroup(group)
            check("F01-H5 deleting the group keeps the server, ungrouped",
                  c.sidebarModel.groups.isEmpty && c.sidebarModel.ungrouped.contains { $0.id == saved.id })
        } else { check("F01-H5 group created", false) }

        // F02-H3 open folders the way people do: double-click and ⌘↓, sent as real events through the window
        for (pane, label) in [(left, "local"), (right, "server")] {
            let start = pane.location.path
            // Wait for the reload to land: clicking while the table is being replaced isn't the case under test.
            pane.reload(); _ = await waitUntil { !pane.isReloading && !pane.entries.isEmpty }
            guard let row = pane.entries.firstIndex(where: \.isDirectory) else { check("F02-H3 \(label) has a folder", false); continue }
            let folder = pane.entries[row]
            doubleClick(pane.tableView, row: row)
            let opened = await waitUntil(5) { pane.location.path == folder.path }
            checkEvent("F02-H3 double-click opens a \(label) folder", opened, "still at \(pane.location.path)")
            pane.navigate(to: pane.location.with(path: start))
            _ = await waitUntil { pane.entries.contains { $0.name == folder.name } }
            if let r2 = pane.entries.firstIndex(where: { $0.name == folder.name }) {
                pane.tableView.selectRowIndexes([r2], byExtendingSelection: false)
                pane.view.window?.makeFirstResponder(pane.tableView)
                key(pane.tableView, code: 125, chars: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: .command)
                let byKey = await waitUntil(5) { pane.location.path == folder.path }
                checkEvent("F02-H3 ⌘↓ opens a \(label) folder", byKey, "still at \(pane.location.path)")
            }
            pane.navigate(to: pane.location.with(path: start))
            _ = await waitUntil { !pane.entries.isEmpty }
        }

        // F02-H4 back / forward history (toolbar, ⌘[ ⌘] and the Go menu all call these)
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { right.entries.contains { $0.name == "releases" } }
        right.navigate(to: right.location.with(path: r("releases")))
        right.navigate(to: right.location.with(path: r("releases/2026-10-01")))
        right.goBack()
        let back1 = right.location.path == r("releases")
        right.goBack()
        let back2 = right.location.path == remoteRoot
        right.goForward()
        let fwd = right.location.path == r("releases")
        check("F02-H4 back, back, forward walks the history", back1 && back2 && fwd, "at \(right.location.path)")
        right.navigate(to: right.location.with(path: r("assets")))
        check("F02-H4 going somewhere new clears Forward", !right.canGoForward && right.canGoBack)
        c.paneDidBecomeActive(right)
        right.view.window?.makeFirstResponder(right.tableView)
        keyThroughApp(code: 33, chars: "[", mods: .command)   // ⌘[ through the menu bar, like a person
        let byKey = await waitUntil(3) { right.location.path == r("releases") }
        check("F02-H4 ⌘[ goes back", byKey, "at \(right.location.path)")
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { !right.entries.isEmpty }

        // F02-H5 the active pane is marked, and the mark follows focus
        right.view.window?.makeFirstResponder(left.tableView)
        let leftActive = left.isActive && !right.isActive
        right.view.window?.makeFirstResponder(right.tableView)
        check("F02-H5 active-pane marker follows focus", leftActive && right.isActive && !left.isActive)

        // F06-H1 sync a local folder to the server, through the sync window's model and the real sheet
        let srcDir = l("syncsrc"), dstDir = r("syncdst")
        try? FileManager.default.createDirectory(atPath: srcDir + "/css", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        try? "home".write(toFile: srcDir + "/index.html", atomically: true, encoding: .utf8)
        try? "body{}".write(toFile: srcDir + "/css/site.css", atomically: true, encoding: .utf8)
        try? "v2".write(toFile: srcDir + "/about.html", atomically: true, encoding: .utf8)
        try? "v1".write(toFile: dstDir + "/about.html", atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: dstDir + "/about.html")
        try? "stale".write(toFile: dstDir + "/old.html", atomically: true, encoding: .utf8)
        let syncModel = SyncModel(left: .local(srcDir), right: right.location.with(path: dstDir))
        syncModel.options.deleteOrphans = true
        c.presentSync(syncModel)
        _ = await waitUntil(10) { syncModel.phase == .ready }
        let p1 = syncModel.plan
        check("F06-H1 compare finds 2 adds, 1 update, 1 delete", p1?.adds == 2 && p1?.updates == 1 && p1?.deletes == 1,
              "adds \(p1?.adds ?? -1) updates \(p1?.updates ?? -1) deletes \(p1?.deletes ?? -1)")
        if let dir = ProcessInfo.processInfo.environment["SHELLPANE_SELFTEST_SCREENS"], let sheet = c.window?.attachedSheet,
           let frame = sheet.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            try? await Task.sleep(for: .milliseconds(300))
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/S10-sync.png"))
        }
        syncModel.sync()   // deletes are confirmed in the view; the model runs what it's given
        _ = await waitUntil(15) { if case .finished = syncModel.phase { return true }; return false }
        let synced = data(dstDir + "/css/site.css") == data(srcDir + "/css/site.css")
            && (try? String(contentsOfFile: dstDir + "/about.html", encoding: .utf8)) == "v2"
            && !FileManager.default.fileExists(atPath: dstDir + "/old.html")
        check("F06-H1 sync copies, updates and deletes", synced)
        syncModel.compare()
        _ = await waitUntil(10) { syncModel.phase == .ready }
        check("F06-H1 comparing again finds nothing to do", syncModel.plan?.hasChanges == false)
        check("F06-N1 a sync with an unsaved server can't be saved, and says why", syncModel.saveProblem != nil)
        syncModel.onClose()

        // F08-H1 Open in Terminal: the .command file the launcher writes, run for real (no terminal window):
        // same file, same ssh arguments, with the login shell swapped for `pwd`
        let weird = r("📁 it's \"here\" $HOME")
        try? FileManager.default.createDirectory(atPath: weird, withIntermediateDirectories: true)
        if let live = right.location.session {
            let args = SSHCommand.shellArguments(for: live.target, path: weird, configFile: ConnectionManager.shared.configFile,
                                                 interactive: false, then: "pwd")
            if let file = try? TerminalLauncher.commandFile(SSHCommand.commandLine("/usr/bin/ssh", args)) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [file.path]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{1b}[H\u{1b}[2J", with: "")
                check("F08-H1 the terminal command logs in and lands in the folder", printed.hasSuffix(weird), "printed \(printed)")
                check("F08-H1 the .command file deletes itself", !FileManager.default.fileExists(atPath: file.path))
            } else { check("F08-H1 command file written", false) }
        }

        // BUG-009 selected rows: every column's text turns to the selected-text colour (readable on the accent)
        right.reload(); _ = await waitUntil { !right.isReloading && !right.entries.isEmpty }
        if let row = right.entries.firstIndex(where: { !$0.isDirectory }),
           let sizeCol = right.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "size" }),
           let cell = right.tableView.view(atColumn: sizeCol, row: row, makeIfNecessary: true) as? NSTableCellView {
            cell.backgroundStyle = .emphasized
            let selectedColour = cell.textField?.textColor
            cell.backgroundStyle = .normal
            let normalColour = cell.textField?.textColor
            check("BUG-009 selected rows switch secondary text to the selected-text colour",
                  selectedColour == NSColor.alternateSelectedControlTextColor && normalColour != NSColor.alternateSelectedControlTextColor,
                  "selected \(String(describing: selectedColour)), normal \(String(describing: normalColour))")
        }

        // FX-1 Commander keys, as key presses through the app
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { !right.isReloading && right.entries.count >= 5 }
        c.paneDidBecomeActive(right)
        right.view.window?.makeFirstResponder(right.tableView)
        right.tableView.selectRowIndexes([0], byExtendingSelection: false)
        right.tableView.setCursor(0)
        let space = { keyThroughApp(code: 49, chars: " ", mods: []) }
        space(); space(); space()
        checkEvent("FX-1 Space marks three items and moves down", right.selectedEntries.count == 3 && right.tableView.cursor == 3,
                   "marked \(right.selectedEntries.count), cursor \(right.tableView.cursor)")
        keyThroughApp(code: 125, chars: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: [])
        checkEvent("FX-1 ↓ moves the cursor and keeps the marks", right.selectedEntries.count == 3 && right.tableView.cursor == 4)
        await screenshot(c.window, "S02-commander.png")
        space()
        checkEvent("FX-1 Space after ↓ adds the item under the cursor", right.selectedEntries.count == 4)
        keyThroughApp(code: 53, chars: "\u{1b}", mods: [])
        checkEvent("FX-1 Esc clears the marks", right.selectedEntries.count == 1 && !right.tableView.marking)
        // F5 on marked files copies them all
        TransferCenter.shared.testResolver = { _ in .init(.replace, applyToAll: true) }
        let files = right.entries.indices.filter { !right.entries[$0].isDirectory }.prefix(2)
        right.tableView.selectRowIndexes([files.first!], byExtendingSelection: false)
        right.tableView.setCursor(files.first!)
        if files.count == 2 {
            right.tableView.toggleMarkAndAdvance()
            right.tableView.setCursor(files.last!)
            right.tableView.toggleMarkAndAdvance()
            let before = TransferCenter.shared.items.count
            keyThroughApp(code: 96, chars: String(UnicodeScalar(NSF5FunctionKey)!), mods: [])
            let item = await startedTransfer(before)
            checkEvent("FX-1 F5 copies the marked items", item?.name == "2 items" && item?.status == .done, "\(String(describing: item?.name)) \(String(describing: item?.status))")
        }
        TransferCenter.shared.testResolver = { _ in .init(.skip) }
        PaneTableView.commanderKeys = false
        right.tableView.selectRowIndexes([0], byExtendingSelection: false)
        right.tableView.endMarking()
        right.tableView.setCursor(0)
        let qlBefore = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        space()   // off: Space is Quick Look (folder at row 0 → beep, nothing marked)
        check("FX-1 with Commander keys off, Space doesn't mark", !right.tableView.marking && right.selectedEntries.count == 1)
        _ = qlBefore
        PaneTableView.commanderKeys = true

        // FX-2 quick filter: "/" opens it, typing narrows the list, Esc restores it
        let total = right.entries.count
        keyThroughApp(code: 44, chars: "/", mods: [])
        let opened = !right.filterField.isHidden
        right.setFilter("rob")
        let narrowed = !right.entries.isEmpty && right.entries.allSatisfy { $0.name.localizedCaseInsensitiveContains("rob") } && right.entries.count < total
        right.clearFilter()
        checkEvent("FX-2 / opens the filter", opened)
        check("FX-2 the filter narrows the list and Esc restores it", narrowed && right.entries.count == total && right.filterField.isHidden)

        // FX-3 F3 Quick Look: local file, and a server file (downloaded first)
        for (pane, label) in [(left, "Mac"), (right, "server")] {
            pane.reload(); _ = await waitUntil { !pane.isReloading && !pane.entries.isEmpty }
            guard let i = pane.entries.firstIndex(where: { !$0.isDirectory }) else { continue }
            c.paneDidBecomeActive(pane)
            pane.view.window?.makeFirstResponder(pane.tableView)
            pane.tableView.selectRowIndexes([i], byExtendingSelection: false)
            pane.tableView.setCursor(i)
            keyThroughApp(code: 99, chars: String(UnicodeScalar(NSF3FunctionKey)!), mods: [])
            let shown = await waitUntil(8) { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible && !QuickLookCenter.shared.urls.isEmpty }
            checkEvent("FX-3 F3 Quick Looks a \(label) file", shown)
            QLPreviewPanel.shared()?.orderOut(nil)
            _ = await waitUntil(2) { !QLPreviewPanel.shared().isVisible }
        }
        c.paneDidBecomeActive(right)

        // FX-4 a failed connection keeps ssh's own words and a test command
        do {
            _ = try await ConnectionManager.shared.connect(SSHTarget(host: "127.0.0.1", port: 1))
            check("FX-4 failed connection explains itself", false, "it connected?")
        } catch let e as SSHConnectError {
            check("FX-4 failed connection explains itself",
                  e.localizedDescription.contains("refused") && e.failure.raw.contains("Connection refused") && e.testCommand.contains("'-v'"),
                  e.failure.raw)
        } catch {
            check("FX-4 failed connection explains itself", false, "\(type(of: error)): \(error.localizedDescription)")
        }

        // F02-H6 tabs: ⌘T, per-tab folder and history, ⌃Tab, ⌘W (all as key presses through the menu bar)
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { right.entries.contains { $0.name == "releases" } }
        c.paneDidBecomeActive(right)
        right.view.window?.makeFirstResponder(right.tableView)
        keyThroughApp(code: 17, chars: "t", mods: .command)                     // ⌘T
        let twoTabs = right.tabs.count == 2 && right.currentTab == 1
        right.navigate(to: right.location.with(path: r("releases")))
        keyThroughApp(code: 48, chars: "\t", mods: [.control, .shift])           // ⌃⇧Tab
        let backInFirst = right.currentTab == 0 && right.location.path == remoteRoot
        keyThroughApp(code: 48, chars: "\t", mods: .control)                     // ⌃Tab
        let secondKept = right.currentTab == 1 && right.location.path == r("releases")
        right.goBack()
        let ownHistory = right.location.path == remoteRoot
        check("F02-H6 ⌘T opens a tab, each tab keeps its folder and history, ⌃Tab switches",
              twoTabs && backInFirst && secondKept && ownHistory,
              "tabs \(right.tabs.count) current \(right.currentTab) at \(right.location.path)")
        await screenshot(c.window, "S02-tabs.png")
        keyThroughApp(code: 13, chars: "w", mods: .command)                     // ⌘W
        check("F02-H6 ⌘W closes the tab, not the window", right.tabs.count == 1 && c.window?.isVisible == true)
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { !right.entries.isEmpty }

        // F02-H8 icon view: ⌘2, every file as an icon, select one, ⌘↓ opens it, ⌘1 back
        c.paneDidBecomeActive(right)
        right.view.window?.makeFirstResponder(right.tableView)
        keyThroughApp(code: 19, chars: "2", mods: .command)                     // ⌘2
        let iconsShown = await waitUntil(3) { right.viewMode == .icons && right.icons.collection.numberOfItems(inSection: 0) == right.entries.count }
        check("F02-H8 ⌘2 shows every file as an icon", iconsShown, "\(right.icons.collection.numberOfItems(inSection: 0)) of \(right.entries.count)")
        if let i = right.entries.firstIndex(where: { $0.name == "releases" }) {
            right.icons.collection.selectionIndexPaths = [IndexPath(item: i, section: 0)]
            check("F02-H8 the icon selection is the pane's selection", right.selectedEntries.map(\.name) == ["releases"])
            await screenshot(c.window, "S02-icons.png")
            right.view.window?.makeFirstResponder(right.icons.collection)
            // Through the app, like a real key press: the menu bar's File › Open (⌘↓) gets it first.
            keyThroughApp(code: 125, chars: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: .command)
            let opened = await waitUntil(5) { right.location.path == r("releases") }
            checkEvent("F02-H8 ⌘↓ on an icon opens the folder", opened, "at \(right.location.path)")
        }
        keyThroughApp(code: 18, chars: "1", mods: .command)                     // ⌘1
        check("F02-H8 ⌘1 goes back to the list", right.viewMode == .list && right.icons.scrollView.isHidden)
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { !right.entries.isEmpty }

        // F02-H7 column view: ⌘3, click a folder (real mouse event), its column fills from the server, ⌘1 back
        c.paneDidBecomeActive(right)
        right.view.window?.makeFirstResponder(right.tableView)
        keyThroughApp(code: 20, chars: "3", mods: .command)                     // ⌘3
        let b = right.columns.browser
        func rowOf(_ name: String, column: Int) -> Int? {
            let n = b.delegate?.browser?(b, numberOfChildrenOfItem: column == 0 ? (right.columns.root as NSString) : b.item(atRow: b.selectedRow(inColumn: column - 1), inColumn: column - 1)) ?? 0
            return (0..<n).first { (b.item(atRow: $0, inColumn: column) as? String).map { ($0 as NSString).lastPathComponent } == name }
        }
        let firstColumn = await waitUntil(8) { right.viewMode == .columns && rowOf("releases", column: 0) != nil }
        check("F02-H7 ⌘3 shows columns and the first column fills", firstColumn)
        if let row = rowOf("releases", column: 0) {
            click(b, rect: b.frame(ofRow: row, inColumn: 0))
            let opened = await waitUntil(8) { right.location.path == r("releases") && rowOf("2026-10-01", column: 1) != nil }
            check("F02-H7 clicking a folder opens its column and moves the path bar", opened, "at \(right.location.path)")
            let value = b.delegate?.browser?(b, objectValueForItem: b.item(atRow: row, inColumn: 0)) as? NSAttributedString
            var hasIcon = false
            value?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value?.length ?? 0)) { a, _, _ in
                if (a as? NSTextAttachment)?.image != nil { hasIcon = true }
            }
            check("F02-H7 column rows have icons", hasIcon)
            check("F02-H7 the selection is what F5 would copy", right.selectedEntries.map(\.name) == ["releases"],
                  "\(right.selectedEntries.map(\.name))")
        }
        await screenshot(c.window, "S02-columns.png")
        keyThroughApp(code: 18, chars: "1", mods: .command)                     // ⌘1
        check("F02-H7 ⌘1 goes back to the list", right.viewMode == .list && !right.tableView.isHidden && b.isHidden)
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { !right.entries.isEmpty }

        // F02-E3 reloading keeps the selection (a transfer finishing or a chmod reloads the pane)
        right.reload(); _ = await waitUntil { right.entries.contains { $0.name == "robots.txt" } }
        if let i = right.entries.firstIndex(where: { $0.name == "robots.txt" }) {
            right.tableView.selectRowIndexes([i], byExtendingSelection: false)
            right.reload()
            try? await Task.sleep(for: .milliseconds(600))
            check("F02-E3 reload keeps the selection", right.selectedEntries.map(\.name) == ["robots.txt"], "\(right.selectedEntries.map(\.name))")
        }

        // F02-H9 folders open in place (list view): → or the triangle shows the contents under the folder,
        // the pane stays where it is, a reload keeps it open, ← goes back up and closes it
        let inside = r("releases/2026-10-01")
        if let i = right.entries.firstIndex(where: { $0.name == "releases" }) {
            right.tableView.selectRowIndexes([i], byExtendingSelection: false)
            key(right.tableView, code: 124, chars: "\u{F703}", mods: [])                 // →
            let opened = await waitUntil(8) { right.entries.contains { $0.path == inside } }
            let row = right.entries.firstIndex { $0.path == inside }
            checkEvent("F02-H9 → shows a folder's contents under it, indented, without leaving the folder",
                       opened && row == i + 1 && row.map { right.depths[$0] } == 1 && right.location.path == remoteRoot,
                       "row \(String(describing: row)), at \(right.location.path)")
            let nameColumn = right.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            let cell = right.tableView.view(atColumn: nameColumn, row: i, makeIfNecessary: true) as? PaneCellView
            check("F02-H9 its triangle shows it open", cell?.disclosure?.state == .on && cell?.disclosure?.isHidden == false)
            right.reload()
            _ = await waitUntil(8) { !right.isReloading }
            check("F02-H9 a reload keeps it open", right.entries.contains { $0.path == inside })
            if let c = right.entries.firstIndex(where: { $0.path == inside }) {
                right.tableView.selectRowIndexes([c], byExtendingSelection: false)
                check("F02-H9 a row inside is what F5 copies", right.selectedEntries.map(\.path) == [inside],
                      "\(right.selectedEntries.map(\.path))")
                key(right.tableView, code: 123, chars: "\u{F702}", mods: [])             // ←
                checkEvent("F02-H9 ← on a row inside goes to its folder", right.selectedEntries.map(\.name) == ["releases"],
                           "\(right.selectedEntries.map(\.name))")
                key(right.tableView, code: 123, chars: "\u{F702}", mods: [])             // ← again
                checkEvent("F02-H9 ← on an open folder hides its contents", !right.entries.contains { $0.path == inside })
            }
            if let j = right.entries.firstIndex(where: { $0.name == "releases" }),
               let button = (right.tableView.view(atColumn: nameColumn, row: j, makeIfNecessary: true) as? PaneCellView)?.disclosure {
                button.performClick(nil)
                let clicked = await waitUntil(8) { right.entries.contains { $0.path == inside } }
                check("F02-H9 clicking the triangle shows the contents", clicked)
                if let k = right.entries.firstIndex(where: { $0.name == "releases" }) { right.setExpanded(false, row: k) }
            }
        } else {
            check("F02-H9 folders open in place", false, "no releases folder")
        }

        // F02-H10 typing a path: relative, "..", a file (its folder opens with it selected), a missing one
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { right.entries.contains { $0.name == "releases" } }
        right.beginEditingPath()
        check("F02-H10 the path field opens holding the current path", !right.pathField.isHidden && right.pathField.stringValue == remoteRoot)
        right.pathField.stringValue = "releases"
        right.commitPath()
        let relative = await waitUntil(8) { right.location.path == r("releases") }
        check("F02-H10 a relative path opens from the current folder, and the field closes",
              relative && right.pathField.isHidden, right.location.path)
        right.beginEditingPath(); right.pathField.stringValue = ".."; right.commitPath()
        check("F02-H10 .. goes up", await waitUntil(8) { right.location.path == remoteRoot }, right.location.path)
        _ = await waitUntil { right.entries.contains { $0.name == "robots.txt" } }
        right.beginEditingPath(); right.pathField.stringValue = r("robots.txt"); right.commitPath()
        let fileOpened = await waitUntil(8) { right.location.path == remoteRoot && right.selectedEntries.map(\.name) == ["robots.txt"] }
        check("F02-H10 a file's path opens its folder with the file selected", fileOpened, "\(right.selectedEntries.map(\.name))")
        right.beginEditingPath(); right.pathField.stringValue = "no-such-folder"; right.commitPath()
        try? await Task.sleep(for: .milliseconds(800))
        check("F02-H10 a path that isn't there keeps the field open and the pane where it was",
              !right.pathField.isHidden && right.location.path == remoteRoot)
        right.endEditingPath()
        check("F02-H10 Esc closes the field", right.pathField.isHidden)

        // F02-H11 the path bar's copy button: the folder's path, or host:path for scp
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        right.copyFolderPath(remoteForm: false)
        check("F02-H11 copy gives the folder's path", NSPasteboard.general.string(forType: .string) == remoteRoot)
        right.copyFolderPath(remoteForm: true)
        let scp = NSPasteboard.general.string(forType: .string) ?? ""
        check("F02-H11 the scp form is host:path", scp == "web-1:" + remoteRoot, scp)
        if let clipboardBefore { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(clipboardBefore, forType: .string) }

        // F01-H6 favorite folders on a server: add, open from either pane (connecting if needed), remove.
        // The pane here was opened through Connect without saving; a plain host still counts, by its name.
        c.pane(right, setBookmarked: true, path: r("releases"))
        let bookmark = c.sidebarModel.bookmarks.first { $0.path == r("releases") }
        check("F01-H6 a server folder becomes a favorite folder, tied to the server",
              (bookmark?.place).map { $0 != .local } == true && c.pane(right, isBookmarked: r("releases")),
              "key \(right.location.session?.key ?? "none"), place \(String(describing: bookmark?.place))")
        if let bookmark {
            c.paneDidBecomeActive(right)
            c.openBookmark(bookmark)
            check("F01-H6 opening it goes there", await waitUntil(8) { right.location.path == r("releases") }, right.location.path)
            let leftBefore = left.location
            c.paneDidBecomeActive(left)
            c.openBookmark(bookmark)
            let connected = await waitUntil(10) { left.location.session != nil && left.location.path == r("releases") }
            check("F01-H6 opening it from a pane on this Mac connects there first", connected, left.location.path)
            left.navigate(to: leftBefore)
            _ = await waitUntil { !left.isReloading }
            c.paneDidBecomeActive(right)
        }
        c.pane(right, setBookmarked: false, path: r("releases"))
        check("F01-H6 removing it takes it out of the sidebar", !c.sidebarModel.bookmarks.contains { $0.path == r("releases") })
        right.navigate(to: right.location.with(path: remoteRoot))
        _ = await waitUntil { !right.entries.isEmpty }

        // F12 the Mac's own sidebar: Finder's Favorites, and Finder's tags (colour from the file, files listed)
        let macPlaces = FinderSidebar.favorites()
        check("F12-H1 Mac Favorites: folders that exist, Macintosh HD last",
              macPlaces.last?.path == "/" && macPlaces.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
              "\(macPlaces.map(\.path))")
        let tagged = l("tagged-report.txt")
        FileManager.default.createFile(atPath: tagged, contents: Data("report\n".utf8))
        // Finder's own format: a list of "name\ncolour" in the file's extended attribute (6 = red).
        if let plist = try? PropertyListSerialization.data(fromPropertyList: ["Shellpane e2e\n6", "Other"], format: .binary, options: 0) {
            _ = plist.withUnsafeBytes { setxattr(tagged, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, plist.count, 0, 0) }
        }
        let colours = FinderTags.colours(at: tagged)
        check("F12-H2 a tag's colour is read the way Finder stores it", colours["Shellpane e2e"] == 6 && colours["Other"] == 0, "\(colours)")
        let realSearch = FinderTags.search
        FinderTags.search = { name in name == "Shellpane e2e" ? [tagged] : [] }
        let tagPane = right
        tagPane.showTag(FinderTag(name: "Shellpane e2e", colour: 6))
        let listed = await waitUntil(8) { tagPane.entries.map(\.path) == [tagged] }
        check("F12-H3 clicking a tag lists the files with it, by their own paths", listed && tagPane.showsTag,
              "\(tagPane.entries.map(\.path))")
        let foldersBefore = left.entries.count
        tagPane.newFolder(nil)
        try? await Task.sleep(for: .milliseconds(300))
        check("F12-H4 a tag view has no folder: New Folder is refused", NSApp.windows.allSatisfy { $0.attachedSheet == nil })
        c.paneDidBecomeActive(left)
        if let i = left.entries.firstIndex(where: { $0.name == "app.js" }) {
            left.tableView.selectRowIndexes([i], byExtendingSelection: false)
            let transfersBefore = TransferCenter.shared.items.count
            c.transferToOtherPane(.copy)
            check("F12-H4 copying into a tag view is refused", TransferCenter.shared.items.count == transfersBefore)
        }
        c.hideActivity()
        check("F12-H4 nothing was added on the Mac side", left.entries.count == foldersBefore)
        tagPane.goBack()
        let leftTag = await waitUntil(8) { !tagPane.showsTag && tagPane.location.session != nil }
        check("F12-H5 Back leaves the tag and returns to the folder", leftTag, tagPane.location.path)
        FinderTags.search = realSearch
        try? FileManager.default.removeItem(atPath: tagged)
        left.reload(); _ = await waitUntil { !left.isReloading }
        c.paneDidBecomeActive(right)

        // F01-H7 a server's icon and colour: chosen in the form, saved, and shown wherever the server is
        let form = ServerFormModel(mode: .connect, configHosts: ["web-1"])
        form.pickAlias("web-1")
        form.name = "Shop"
        form.icon = "cart"
        form.colour = .pink
        var submitted: Favorite?
        form.onSubmit = { f, _, _, _ in submitted = f }
        form.submit()
        check("F01-H7 an ssh_config host saved with no username lets ssh decide (no -l '')", submitted?.username == nil
              && submitted?.target.user == nil, "\(String(describing: submitted?.username))")
        check("F01-H7 the form keeps the chosen icon and colour", submitted?.icon == "cart" && submitted?.colour == "pink",
              "\(String(describing: submitted?.icon)) \(String(describing: submitted?.colour))")
        if let shop = submitted {
            try? ConnectionManager.shared.favorites.save(shop)
            c.sidebarModel.reloadFavorites()
            let saved = c.sidebarModel.favorites.first { $0.id == shop.id }
            check("F01-H7 saved and listed with them", saved?.icon == "cart" && saved?.colour == "pink")
            let before = right.location
            c.paneDidBecomeActive(right)
            // The same server may already be open: the connection is shared, so wait for the folder, not the key.
            c.connect(shop, path: r("releases"))
            let opened = await waitUntil(10) { right.location.path == r("releases") && right.location.session != nil }
            if opened, let session = right.location.session {
                let look = c.appearance(of: session, openedAs: right.openedAs)
                check("F01-H7 the path bar shows the icon and colour of the server you opened, even on a shared connection",
                      look.icon == "cart" && look.colour == .pink,
                      "got \(String(describing: look.icon)) \(look.colour), key \(session.key), shop \(shop.id), same target: \(c.sidebarModel.favorites.filter { $0.target == session.target }.map(\.name))")
            } else {
                check("F01-H7 the path bar shows the server's icon and colour", false,
                      "at \(right.location.path) key \(right.location.session?.key ?? "none") failed \(c.sidebarModel.failed) fav \(shop.sshAlias ?? "-")/\(shop.host ?? "-") auth \(shop.auth)")
            }
            right.navigate(to: before)
            _ = await waitUntil { !right.isReloading }
            try? ConnectionManager.shared.favorites.delete(id: shop.id)
            c.sidebarModel.reloadFavorites()
        }

        // F07-H4 hidden files
        check("F07-H4 hidden files hidden by default", !right.entries.contains { $0.name == ".htaccess" })
        right.showHidden = true
        check("F07-H4 hidden files shown when toggled", right.entries.contains { $0.name == ".htaccess" })
        right.showHidden = false

        // F03-H2 drag a local file onto the server pane
        var before = TransferCenter.shared.items.count
        if let drop = FakeDrag.from(left, names: ["app.js"]) {
            let op = right.tableView(right.tableView, validateDrop: drop, proposedRow: -1, proposedDropOperation: .above)
            check("F03-H2 drop local→server offers copy", op == .copy, "got \(op)")
            _ = right.tableView(right.tableView, acceptDrop: drop, row: -1, dropOperation: .on)
            _ = await startedTransfer(before)
            check("F03-H2 dropped file uploaded byte-identical", data(r("app.js")) != nil && data(r("app.js")) == data(l("app.js")))
        } else { check("F03-H2 drag setup", false) }

        // F03-E1 drop onto a folder row uploads into that folder
        right.reload(); _ = await waitUntil { right.entries.contains { $0.name == "app.js" } }
        before = TransferCenter.shared.items.count
        if let drop = FakeDrag.from(left, names: ["styles.css"]),
           let row = right.entries.firstIndex(where: { $0.name == "releases" }) {
            _ = right.tableView(right.tableView, validateDrop: drop, proposedRow: row, proposedDropOperation: .on)
            _ = right.tableView(right.tableView, acceptDrop: drop, row: row, dropOperation: .on)
            _ = await startedTransfer(before)
            check("F03-E1 drop on a folder row goes into that folder", data(r("releases/styles.css")) == data(l("styles.css")))
        } else { check("F03-E1 drag setup", false) }

        // F07-H3 drag within one server onto a folder = move (a rename, instant)
        right.reload(); _ = await waitUntil { right.entries.contains { $0.name == "deploy.sh" } }
        before = TransferCenter.shared.items.count
        if let drop = FakeDrag.from(right, names: ["deploy.sh"]),
           let row = right.entries.firstIndex(where: { $0.name == "releases" }) {
            let op = right.tableView(right.tableView, validateDrop: drop, proposedRow: row, proposedDropOperation: .on)
            check("F07-H3 drag within a server offers move", op == .move, "got \(op)")
            _ = right.tableView(right.tableView, acceptDrop: drop, row: row, dropOperation: .on)
            _ = await startedTransfer(before)
            check("F07-H3 moved into the folder and gone from the old place",
                  data(r("releases/deploy.sh")) != nil && data(r("deploy.sh")) == nil)
        } else { check("F07-H3 drag setup", false) }

        // F03-E2 dropping onto the folder it came from does nothing
        right.reload(); _ = await waitUntil { !right.entries.isEmpty }
        if let drop = FakeDrag.from(right, names: ["index.html"]) {
            let op = right.tableView(right.tableView, validateDrop: drop, proposedRow: -1, proposedDropOperation: .above)
            check("F03-E2 drop onto its own folder is refused", op == [], "got \(op)")
        }

        // F03-H3 Finder → server pane
        let finderFile = l("from-finder.txt")
        try? "dragged from Finder".write(toFile: finderFile, atomically: true, encoding: .utf8)
        before = TransferCenter.shared.items.count
        let finderDrop = FakeDrag(urls: [URL(fileURLWithPath: finderFile)])
        let finderOp = right.tableView(right.tableView, validateDrop: finderDrop, proposedRow: -1, proposedDropOperation: .above)
        check("F03-H3 Finder drop offers copy", finderOp == .copy, "got \(finderOp)")
        _ = right.tableView(right.tableView, acceptDrop: finderDrop, row: -1, dropOperation: .on)
        _ = await startedTransfer(before)
        check("F03-H3 Finder file uploaded", data(r("from-finder.txt")) == data(finderFile))

        // F04-H2 server → Finder (file promise), for a file and a folder
        let promiseDir = l("promised")
        try? FileManager.default.createDirectory(atPath: promiseDir, withIntermediateDirectories: true)
        for name in ["index.html", "assets"] {
            guard let entry = right.entries.first(where: { $0.name == name }) else { check("F04-H2 promise \(name) setup", false); continue }
            let delegate = RemotePromiseDelegate(entry: entry, client: session.client)
            let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)
            let dest = URL(fileURLWithPath: RemotePath.join(promiseDir, name))
            let errorBox = ErrorHolder()
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                delegate.operationQueue(for: provider).addOperation {
                    delegate.filePromiseProvider(provider, writePromiseTo: dest) { errorBox.error = $0; k.resume() }
                }
            }
            if name == "assets" {
                check("F04-H2 folder dragged to Finder arrives whole", errorBox.error == nil &&
                      data(RemotePath.join(promiseDir, "assets/img/icons/menu.svg")) == data(r("assets/img/icons/menu.svg")))
            } else {
                check("F04-H2 file dragged to Finder arrives", errorBox.error == nil && data(dest.path) == data(r(name)))
            }
        }

        // F03-E3 conflicts: keep both, then replace
        for (choice, expect) in [(ConflictChoice.keepBoth, "robots 2.txt"), (.replace, "robots.txt")] {
            TransferCenter.shared.testResolver = { _ in .init(choice) }
            try? "local robots v\(choice.rawValue)".write(toFile: l("robots.txt"), atomically: true, encoding: .utf8)
            left.reload(); _ = await waitUntil { left.entries.contains { $0.name == "robots.txt" } }
            before = TransferCenter.shared.items.count
            if let drop = FakeDrag.from(left, names: ["robots.txt"]) {
                _ = right.tableView(right.tableView, acceptDrop: drop, row: -1, dropOperation: .on)
                _ = await startedTransfer(before)
                check("F03-E3 conflict → \(choice.rawValue)", data(r(expect)) == data(l("robots.txt")))
            }
        }
        TransferCenter.shared.testResolver = { _ in .init(.skip) }

        // F07-H1 rename, and the cases around it
        right.reload(); _ = await waitUntil { right.entries.contains { $0.name == "styles.css" } }
        if let css = right.entries.first(where: { $0.name == "styles.css" }) {
            do {
                try await right.performRename(css, to: "main.css")
                check("F07-H1 rename on the server", data(r("main.css")) != nil && data(r("styles.css")) == nil)
            } catch { check("F07-H1 rename on the server", false, error.localizedDescription) }
        }
        _ = await waitUntil { right.entries.contains { $0.name == "main.css" } }
        if let main = right.entries.first(where: { $0.name == "main.css" }) {
            do {
                try await right.performRename(main, to: "index.html")
                check("F07-N1 rename onto an existing name is refused", false, "it was allowed")
            } catch {
                check("F07-N1 rename onto an existing name is refused, nothing lost",
                      data(r("main.css")) != nil && data(r("index.html")) != nil)
            }
            do {
                try await right.performRename(main, to: "bad/name")
                check("F07-N2 a name with “/” is refused", false, "it was allowed")
            } catch { check("F07-N2 a name with “/” is refused", true) }
        }
        _ = await waitUntil { left.entries.contains { $0.name == "release.zip" } }
        if let zip = left.entries.first(where: { $0.name == "release.zip" }) {
            do {
                try await left.performRename(zip, to: "Release.zip")
                let names = (try? FileManager.default.contentsOfDirectory(atPath: localRoot)) ?? []
                check("F07-E1 change only the case of a local name", names.contains("Release.zip"), "names: \(names)")
            } catch { check("F07-E1 change only the case of a local name", false, error.localizedDescription) }
        }

        // F07-H2 new folder with emoji and accents, then a round trip of an accented file through it
        let folderName = "📁 Fotos Ñandú"
        do {
            try await right.performNewFolder(folderName)
            check("F07-H2 new folder with emoji and accents", FileManager.default.fileExists(atPath: r(folderName)))
        } catch { check("F07-H2 new folder with emoji and accents", false, error.localizedDescription) }
        let accented = "café ☕️ résumé.txt"
        try? "unicode".write(toFile: l(accented), atomically: true, encoding: .utf8)
        left.reload(); _ = await waitUntil { left.entries.contains { $0.name == accented } }
        if let e = left.entries.first(where: { $0.name == accented }) {
            before = TransferCenter.shared.items.count
            TransferCenter.shared.start(.copy, [e], from: left.location, to: right.location.with(path: r(folderName))) {}
            _ = await startedTransfer(before)
            check("F03-E4 accented + emoji file name survives upload", data(RemotePath.join(r(folderName), accented)) == data(l(accented)))
        }

        // F03-E5 a 250-character name
        let long = String(repeating: "a", count: 246) + ".txt"
        try? "long".write(toFile: l(long), atomically: true, encoding: .utf8)
        left.reload(); _ = await waitUntil { left.entries.contains { $0.name == long } }
        if let e = left.entries.first(where: { $0.name == long }) {
            before = TransferCenter.shared.items.count
            TransferCenter.shared.start(.copy, [e], from: left.location, to: right.location) {}
            let item = await startedTransfer(before)
            check("F03-E5 250-character file name uploads", data(r(long)) != nil, "status: \(String(describing: item?.status))")
        }

        // F03-N1 no permission to write: fails cleanly, says why, leaves nothing behind
        let locked = r("locked")
        try? FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        if let e = left.entries.first(where: { $0.name == "index.html" }) {
            before = TransferCenter.shared.items.count
            TransferCenter.shared.start(.copy, [e], from: left.location, to: right.location.with(path: locked)) {}
            let item = await startedTransfer(before)
            var failedState = false
            if case .failed = item?.status { failedState = true }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: locked)) ?? []
            check("F03-N1 upload into a read-only folder fails clearly",
                  failedState && item?.failures.first?.message.lowercased().contains("permission") == true && leftovers.isEmpty,
                  "status \(String(describing: item?.status)) failures \(String(describing: item?.failures)) leftovers \(leftovers)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)

        // F07-H5 delete a nested folder on the server
        right.reload(); _ = await waitUntil { right.entries.contains { $0.name == "assets" } }
        if let assets = right.entries.first(where: { $0.name == "assets" }) {
            let failures = await right.performRemoteDelete([assets])
            check("F07-H5 delete a nested folder on the server", failures.isEmpty && !FileManager.default.fileExists(atPath: r("assets")), "\(failures)")
        }

        // F05-H1 edit a server file: a save goes back up
        right.reload(); _ = await waitUntil { right.entries.contains { $0.name == "index.html" } }
        if let idx = right.entries.first(where: { $0.name == "index.html" }) {
            right.editRemote(idx, with: nil)
            let root = RemoteEditManager.editRoot
            var localCopy: String?
            _ = await waitUntil {
                localCopy = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }
                    .first { $0.hasSuffix("/index.html") }.map { root.appendingPathComponent($0).path }
                return localCopy != nil
            }
            if let localCopy {
                try? await Task.sleep(for: .milliseconds(1500))
                try? "<h1>edited in my editor</h1>".write(toFile: localCopy, atomically: true, encoding: .utf8)
                let uploaded = await waitUntil(8) { (try? String(contentsOfFile: r("index.html"), encoding: .utf8)) == "<h1>edited in my editor</h1>" }
                check("F05-H1 a save in the editor reaches the server", uploaded)
            } else { check("F05-H1 edit opens a local copy", false) }
        }

        // F07-H6 info + chmod through the inspector (⌥⌘I as a key press), on a server file
        right.reload(); _ = await waitUntil { right.entries.contains { $0.name == "index.html" } }
        c.paneDidBecomeActive(right)
        right.view.window?.makeFirstResponder(right.tableView)
        keyThroughApp(code: 34, chars: "i", mods: [.command, .option])          // ⌥⌘I
        check("F07-H6 ⌥⌘I shows the inspector", c.isInspectorShown)
        if let i = right.entries.firstIndex(where: { $0.name == "index.html" }) {
            right.tableView.selectRowIndexes([i], byExtendingSelection: false)
            _ = await waitUntil { c.inspectorModel.single?.name == "index.html" }
            c.inspectorModel.octal = "750"
            c.inspectorModel.octalCommitted()
            c.inspectorModel.applyPermissions()
            let applied = await waitUntil(5) {
                ((try? FileManager.default.attributesOfItem(atPath: r("index.html"))[.posixPermissions]) as? NSNumber)?.intValue == 0o750
            }
            check("F07-H6 chmod 750 from the inspector reaches the server", applied)
            await screenshot(c.window, "S11-info.png")
        }
        if let i = right.entries.firstIndex(where: { $0.name == "releases" }) {
            right.tableView.selectRowIndexes([i], byExtendingSelection: false)
            _ = await waitUntil { c.inspectorModel.single?.name == "releases" }
            c.inspectorModel.calculateSize()
            let counted = await waitUntil(8) { !c.inspectorModel.calculating && c.inspectorModel.folderSize != nil }
            let expected = FileManager.default.enumerator(atPath: r("releases"))?.allObjects.compactMap { $0 as? String }
                .filter { !(((try? FileManager.default.attributesOfItem(atPath: r("releases/" + $0))[.type]) as? FileAttributeType) == .typeDirectory) }.count ?? -1
            check("F07-H7 folder size counts every file", counted && c.inspectorModel.folderSize?.files == expected,
                  "got \(String(describing: c.inspectorModel.folderSize?.files)), expected \(expected)")
        }

        // F09-H1 the operation log records what happened
        c.inspectorModel.tab = .log
        c.inspectorModel.reloadLog()
        let ops = Set(c.inspectorModel.log.map(\.operation))
        check("F09-H1 log has connect, upload, rename, mkdir, delete, chmod, sync, edit",
              ops.isSuperset(of: [.connect, .upload, .rename, .mkdir, .delete, .chmod, .sync, .editUpload]),
              "has \(ops.map(\.rawValue).sorted())")
        await screenshot(c.window, "S09-log.png")
        c.inspectorModel.tab = .info
        c.toggleInspector(nil)

        // F03-H4 queue, pause and bandwidth: with uploads limited, a third transfer waits; pause holds one
        let slowDir = l("slow")
        try? FileManager.default.createDirectory(atPath: slowDir, withIntermediateDirectories: true)
        for i in 0..<3 { try? Data(count: 600_000).write(to: URL(fileURLWithPath: slowDir + "/big\(i).bin")) }
        await BandwidthLimiter.uploads.setLimit(400_000)
        let slowEntries = LocalFS.listSafe(slowDir)
        let firstNew = TransferCenter.shared.items.count
        for e in slowEntries { TransferCenter.shared.start(.copy, [e], from: .local(slowDir), to: right.location) {} }
        _ = await waitUntil(3) { TransferCenter.shared.items.count == firstNew + 3 }
        let newItems = Array(TransferCenter.shared.items[firstNew...])
        check("F03-H4 two transfers run, the third waits its turn", newItems.count == 3 && newItems[2].isWaiting && !newItems[0].isWaiting)
        _ = await waitUntil(5) { newItems[0].batch != nil && newItems[0].bytesDone > 0 }
        newItems[0].togglePause()
        try? await Task.sleep(for: .milliseconds(400))
        let held = newItems[0].bytesDone
        try? await Task.sleep(for: .milliseconds(800))
        check("F03-H4 pause holds a transfer", newItems[0].bytesDone == held && newItems[0].status == .paused, "\(held) → \(newItems[0].bytesDone)")
        newItems[0].togglePause()
        await BandwidthLimiter.uploads.setLimit(0)
        let allDone = await waitUntil(30) { newItems.allSatisfy { $0.status == .done } }
        check("F03-H4 resume finishes, and the waiting one ran", allDone && (0..<3).allSatisfy { data(r("big\($0).bin"))?.count == 600_000 })

        // F02-E1 the connection drops: next action reconnects quietly
        kill(session.client.transport.processIdentifier, SIGKILL)
        _ = await waitUntil { !session.isAlive }
        right.reload()
        let back = await waitUntil(15) { right.location.session?.isAlive == true && right.entries.contains { $0.name == "index.html" } }
        check("F02-E1 dropped connection reconnects on its own", back)

        // F02-E2 a folder deleted underneath you shows an error, not a crash
        try? FileManager.default.createDirectory(atPath: r("vanishing"), withIntermediateDirectories: true)
        right.navigate(to: right.location.with(path: r("vanishing")))
        _ = await waitUntil { right.entries.isEmpty }
        try? FileManager.default.removeItem(atPath: r("vanishing"))
        right.reload()
        try? await Task.sleep(for: .milliseconds(800))
        check("F02-E2 reloading a deleted folder keeps the app alive", right.entries.isEmpty)
    }
}

final class ErrorHolder: @unchecked Sendable { var error: Error? }

/// Stands in for AppKit's drag info so the real validateDrop / acceptDrop code runs.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.shellpane.selftest.\(UUID().uuidString)"))

    /// Simulates dragging these rows out of `pane` (the same writers a real drag uses).
    @MainActor static func from(_ pane: PaneViewController, names: [String]) -> FakeDrag? {
        let rows = names.compactMap { n in pane.entries.firstIndex { $0.name == n } }
        guard rows.count == names.count else { return nil }
        let drag = FakeDrag()
        drag.pasteboard.clearContents()
        let writers = rows.compactMap { pane.tableView(pane.tableView, pasteboardWriterForRow: $0) }
        drag.pasteboard.writeObjects(writers)
        pane.draggedEntries = rows.map { pane.entries[$0] }
        return drag
    }

    convenience init(urls: [URL]) {
        self.init()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    deinit { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
