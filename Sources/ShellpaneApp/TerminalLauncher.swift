import AppKit
import ShellpaneCore
import SSHProcess

/// F08: open the folder a pane shows in a terminal, on the server over ssh or here on the Mac.
@MainActor
enum TerminalLauncher {
    struct App: Equatable {
        let bundleID: String
        let name: String
        /// How it runs a command: Terminal and iTerm open .command files; Ghostty takes `-e`; Warp uses a launch configuration.
        let runsCommandFiles: Bool
        var isWarp: Bool { bundleID == "dev.warp.Warp-Stable" }
    }

    static let known: [App] = [
        App(bundleID: "com.apple.Terminal", name: "Terminal", runsCommandFiles: true),
        App(bundleID: "com.googlecode.iterm2", name: "iTerm", runsCommandFiles: true),
        App(bundleID: "com.mitchellh.ghostty", name: "Ghostty", runsCommandFiles: false),
        App(bundleID: "dev.warp.Warp-Stable", name: "Warp", runsCommandFiles: false),
    ]

    static var installed: [App] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    private static let preferenceKey = "ShellpaneTerminalApp"

    /// The person's choice, if still installed; otherwise Terminal.
    static var preferred: App {
        let id = UserDefaults.standard.string(forKey: preferenceKey)
        return installed.first { $0.bundleID == id } ?? known[0]
    }

    static func setPreferred(_ app: App) {
        UserDefaults.standard.set(app.bundleID, forKey: preferenceKey)
    }

    static func open(_ location: Location, in app: App? = nil) throws {
        let app = app ?? preferred
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(app.name) isn't installed."])
        }
        if app.isWarp { return try openInWarp(location) }
        switch location {
        case let .local(path):
            if app.runsCommandFiles {
                NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                launch(appURL, arguments: ["--working-directory=" + path])
            }
        case let .remote(session, path):
            let args = SSHCommand.shellArguments(for: session.target, path: path, configFile: ConnectionManager.shared.configFile)
            if app.runsCommandFiles {
                let file = try commandFile(SSHCommand.commandLine("/usr/bin/ssh", args))
                NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                launch(appURL, arguments: ["-e", "/usr/bin/ssh"] + args)
            }
        }
    }

    /// Warp: a local folder opens with its new-tab URL; ssh goes through one launch configuration, "Shellpane",
    /// rewritten each time (so Warp's list gains one entry, not one per use).
    private static func openInWarp(_ location: Location) throws {
        switch location {
        case let .local(path):
            var c = URLComponents(string: "warp://action/new_tab")!
            c.queryItems = [URLQueryItem(name: "path", value: path)]
            if let url = c.url { NSWorkspace.shared.open(url) }
        case let .remote(session, path):
            let args = SSHCommand.shellArguments(for: session.target, path: path, configFile: ConnectionManager.shared.configFile)
            let file = try warpConfigurationFile(title: "\(session.label): \((path as NSString).lastPathComponent)",
                                                 command: SSHCommand.commandLine("/usr/bin/ssh", args))
            if let url = URL(string: "warp://launch/" + file.lastPathComponent) { NSWorkspace.shared.open(url) }
        }
    }

    static func warpConfigurationFile(title: String, command: String) throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".warp/launch_configurations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shellpane.yaml")
        let yaml = SSHCommand.warpLaunchConfiguration(name: "Shellpane", title: title,
                                                       cwd: FileManager.default.homeDirectoryForCurrentUser.path, command: command)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func launch(_ appURL: URL, arguments: [String]) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    /// A one-shot script the terminal runs. It deletes itself first, so nothing piles up.
    static func commandFile(_ commandLine: String) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Shellpane/Terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("shellpane-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/sh\nrm -f -- \"$0\"\nclear\nexec \(commandLine)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
