// Design-system check: every custom primitive in every state, light and dark side by side.
//
//   swift run ShellpaneGallery                          opens a window
//   swift run ShellpaneGallery --snapshot gallery.png   renders offscreen to a PNG and exits

import AppKit
import ShellpaneUI
import SwiftUI

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.Colors.textMuted)
            content
        }
    }
}

struct Gallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s24) {
            Section(title: "Connection colours · connected / connecting / disconnected / error") {
                VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                    HStack(spacing: Tokens.Space.s12) {
                        ForEach(ConnectionColour.allCases, id: \.self) { c in
                            ConnectionDot(colour: c, state: .connected)
                        }
                    }
                    HStack(spacing: Tokens.Space.s12) {
                        ConnectionDot(colour: .blue, state: .connected)
                        ConnectionDot(colour: .blue, state: .connecting)
                        ConnectionDot(colour: .blue, state: .disconnected)
                        ConnectionDot(colour: .blue, state: .error)
                    }
                }
            }

            Section(title: "Path bar · local / remote") {
                VStack(spacing: Tokens.Space.s8) {
                    PathBar(remote: nil, path: "/Users/sam/Sites/blog")
                    PathBar(remote: .init(user: "deploy", host: "web-1.example.com", colour: .green),
                            path: "/var/www/blog/releases")
                    PathBar(remote: .init(user: "root", host: "db.example.net", colour: .red), path: "/etc")
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Colors.border))
            }

            Section(title: "Error banners") {
                VStack(spacing: Tokens.Space.s8) {
                    ErrorBanner(severity: .danger,
                                message: "Couldn't sign in to web-1.example.com. The server rejected the key and password.",
                                details: "deploy@web-1.example.com: Permission denied (publickey,password).",
                                actionTitle: "Edit Server…")
                    ErrorBanner(severity: .warning, message: "Connection lost. Reconnecting in 3 s…",
                                actionTitle: "Reconnect Now")
                }
            }

            Section(title: "Activity · every transfer state") {
                VStack(spacing: 0) {
                    ProgressRow(kind: .upload, name: "site-backup-2026-10-11.tar.gz", destination: "web-1:/var/backups",
                                bytesDone: 52_400_000, bytesTotal: 180_000_000,
                                status: .running(bytesPerSecond: 4_300_000, secondsLeft: 31))
                    Divider()
                    ProgressRow(kind: .download, name: "access.log", destination: "~/Downloads",
                                bytesDone: 8_000_000, bytesTotal: 24_000_000, status: .paused)
                    Divider()
                    ProgressRow(kind: .upload, name: "index.html", destination: "web-1:/var/www",
                                bytesDone: 0, bytesTotal: 14_200, status: .queued)
                    Divider()
                    ProgressRow(kind: .upload, name: "styles.css", destination: "web-1:/var/www",
                                bytesDone: 0, bytesTotal: 9_100, status: .waitingConflict)
                    Divider()
                    ProgressRow(kind: .download, name: "db.sqlite", destination: "~/Downloads",
                                bytesDone: 3_000_000, bytesTotal: 90_000_000,
                                status: .failed("Connection lost at 3 MB. Retry resumes from there."))
                    Divider()
                    ProgressRow(kind: .copy, name: "uploads/", destination: "staging:/srv/uploads",
                                bytesDone: 412_000_000, bytesTotal: 412_000_000, status: .done)
                }
                .background(Tokens.Colors.bg)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.Colors.border))
            }

            Section(title: "Empty states") {
                HStack(spacing: Tokens.Space.s12) {
                    EmptyState(symbol: "folder", title: "This folder is empty",
                               message: "Drag files here to upload them.")
                    EmptyState(symbol: "lock", title: "No access",
                               message: "Your account on this server can't open this folder.", tone: .danger)
                    EmptyState(symbol: "server.rack", title: "Add your first server",
                               message: "Or pick one from your ~/.ssh/config.", actionTitle: "Add Server…")
                }
                .frame(height: 230)
                .background(Tokens.Colors.bg)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.Colors.border))
            }

            Section(title: "Status bar") {
                VStack(spacing: Tokens.Space.s8) {
                    StatusBar(leading: "3 of 128 selected, 4.2 MB", trailing: "SFTP · OpenSSH_9.6 · 34 ms")
                    StatusBar(leading: "Listing 12,400 items…", trailing: "212 GB available", busy: true)
                }
            }
        }
        .padding(Tokens.Space.s24)
        .frame(width: 760)
        .background(Tokens.Colors.surface)
    }
}

struct SideBySide: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Gallery().environment(\.colorScheme, .light)
            Gallery().environment(\.colorScheme, .dark)
        }
    }
}

@MainActor
func snapshot(to path: String) -> Bool {
    // A real NSHostingView in an offscreen window, not ImageRenderer: ImageRenderer can't draw
    // AppKit-backed controls (buttons, progress bars) and leaves placeholders. No screen-recording permission needed.
    func render(_ appearance: NSAppearance.Name, scheme: ColorScheme) -> NSImage? {
        let host = NSHostingView(rootView: Gallery().environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
    guard let light = render(.aqua, scheme: .light), let dark = render(.darkAqua, scheme: .dark) else { return false }
    let size = NSSize(width: light.size.width + dark.size.width, height: max(light.size.height, dark.size.height))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    light.draw(in: NSRect(x: 0, y: size.height - light.size.height, width: light.size.width, height: light.size.height))
    dark.draw(in: NSRect(x: light.size.width, y: size.height - dark.size.height, width: dark.size.width, height: dark.size.height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return FileManager.default.createFile(atPath: path, contents: png)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: ScrollView { SideBySide() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1520, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Shellpane Design System"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let ok = MainActor.assumeIsolated { snapshot(to: args[i + 1]) }
    print(ok ? "wrote \(args[i + 1])" : "snapshot failed")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
