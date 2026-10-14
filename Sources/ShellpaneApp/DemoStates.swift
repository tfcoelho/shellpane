import AppKit
import ShellpaneCore
import ShellpaneUI
import SFTPKit
import SSHProcess

/// `--states DIR`: plays the launch video's story against the demo server and saves the window after every
/// step at 3×, with `states.json` listing them in order. When the server form is open, its sheet is saved too,
/// with where it sits on the window. The video project animates between these real states at 60 fps
/// (scripts/video-footage.sh): Shellpane's own changes are instant, so all the motion can come from the camera.
///
///   --left PATH          the local project (left pane)
///   --server-root PATH   the demo site on the server (Production web opens there)
///   --shop-root PATH     the folder the new "Client shop" server opens at
@MainActor
enum DemoStates {
    static func run(_ controller: MainWindowController, to dir: String, arguments args: [String]) {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let window = controller.window, let frameView = window.contentView?.superview,
              let localPath = value("--left"), let serverRoot = value("--server-root"), let shopRoot = value("--shop-root") else {
            print("usage: --states DIR --left PATH --server-root PATH --shop-root PATH"); exit(2)
        }
        if args.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var states: [[String: Any]] = []
        func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(for: .seconds(seconds)) }
        func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<100 where !condition() { await settle(0.1) }
            await settle()
        }
        /// A view at 3× its point size, so the video can zoom in without softening.
        func image(of view: NSView) -> Data? {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let size = view.bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3), pixelsHigh: Int(size.height * 3),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        /// The window as it is now, and the open sheet with its place on the window (fractions, from the top left).
        func capture(_ name: String) {
            if !window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            let base = String(format: "%02d-%@", states.count, name)
            var entry: [String: Any] = ["name": name, "file": base + ".png"]
            try? image(of: frameView)?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(base + ".png"))
            if let sheet = controller.formSheet, let sheetView = sheet.contentView?.superview {
                try? image(of: sheetView)?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(base + "-sheet.png"))
                let w = window.frame, f = sheet.frame
                entry["sheet"] = base + "-sheet.png"
                entry["sheetFrame"] = [(f.minX - w.minX) / w.width, (w.maxY - f.maxY) / w.height, f.width / w.width, f.height / w.height]
            }
            states.append(entry)
        }

        // An organised sidebar to start from: three servers with their own icons and colours, a group for
        // clients, and two favourite folders on Production.
        let cm = ConnectionManager.shared
        let clients = try? cm.groups.create("Clients")
        let production = Favorite(name: "Production web", sshAlias: "acme-web", colour: "green", icon: "globe")
        for fav in [production,
                    Favorite(name: "Staging", sshAlias: "staging", colour: "orange", icon: "flask"),
                    Favorite(name: "Backups NAS", sshAlias: "db-backup", colour: "purple", icon: "externaldrive.connected.to.line.below")] {
            try? cm.favorites.save(fav)
        }
        _ = try? cm.bookmarks.add(name: "acme-site", place: .favorite(production.id), path: serverRoot)
        _ = try? cm.bookmarks.add(name: "assets", place: .favorite(production.id), path: RemotePath.join(serverRoot, "assets"))
        controller.sidebarModel.reloadFavorites()
        controller.sidebarModel.reloadBookmarks()
        controller.sidebarModel.reloadMac()
        controller.left.navigate(to: .local(localPath))
        controller.right.navigate(to: .local(localPath))

        Task { @MainActor in
            await settle(1.0)
            // 1. The organised sidebar, Production open on the right.
            controller.paneDidBecomeActive(controller.right)
            controller.connect(production, path: serverRoot)
            await waitFor { controller.right.location.session != nil && !controller.right.entries.isEmpty }
            capture("overview")

            // 2. Add a server: the form, filled in step by step.
            controller.showServerForm(.connect)
            await waitFor { controller.formModel != nil }
            guard let form = controller.formModel else { print("the form didn't open"); exit(1) }
            capture("form-empty")
            for typed in ["shop.", "shop.example.com"] {
                form.server = typed
                await settle(0.2)
                capture("form-host")
            }
            form.serverCommitted()
            for typed in ["Client", "Client shop"] {
                form.name = typed
                form.nameChanged()
                await settle(0.2)
                capture("form-name")
            }
            // Trying a couple before settling, as people do: each click recolours the preview.
            for colour in [ConnectionColour.green, .purple, .pink] {
                form.colour = colour
                await settle(0.2)
                capture("form-colour")
            }
            for icon in ["globe", "flask", "cart"] {
                form.icon = icon
                await settle(0.2)
                capture("form-icon")
            }
            if let clients { form.groupID = clients.id }
            form.initialPath = shopRoot   // so it opens on the shop's folder, not the account's home
            await settle(0.2)
            capture("form-group")
            form.submit()
            await waitFor { controller.formSheet == nil && controller.right.location.session?.target.host == "shop.example.com"
                && !controller.right.entries.isEmpty }
            capture("added")

            // 3. A Finder tag: everything tagged "Client" in the left pane, then F5 to the client's server.
            controller.paneDidBecomeActive(controller.left)
            controller.left.showTag(FinderTag(name: "Client", colour: 6))
            await waitFor { controller.left.entries.count >= 2 }
            capture("tag")
            window.makeFirstResponder(controller.left.tableView)
            controller.left.tableView.selectRowIndexes(IndexSet(controller.left.entries.indices), byExtendingSelection: false)
            await settle(0.2)
            capture("tag-selected")
            let names = controller.left.entries.map(\.name)
            controller.transferToOtherPane(.copy)
            controller.hideActivity()
            await waitFor { Set(names).isSubset(of: Set(controller.right.entries.map(\.name))) }
            capture("copied")

            // 4. A favourite folder opens on its server.
            controller.paneDidBecomeActive(controller.right)
            if let assets = controller.sidebarModel.bookmarks.first(where: { $0.name == "assets" }) {
                controller.openBookmark(assets)
                await waitFor { controller.right.location.path.hasSuffix("/assets") && !controller.right.entries.isEmpty }
                capture("bookmark")
            }

            let json = try? JSONSerialization.data(withJSONObject: ["states": states], options: [.prettyPrinted, .sortedKeys])
            try? json?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("states.json"))
            print("wrote \(states.count) states to \(dir)")
            ConnectionManager.shared.closeAll()
            exit(0)
        }
    }
}
