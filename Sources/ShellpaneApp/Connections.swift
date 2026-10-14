import AppKit
import ShellpaneCore
import ShellpaneUI
import SFTPKit
import SSHProcess

/// Owns the askpass bridge, saved servers, secrets and open sessions. One per app.
@MainActor
final class ConnectionManager {
    static let shared = ConnectionManager()

    /// Dev and test hook: an ssh_config to use instead of ~/.ssh/config (passed to ssh as -F).
    let configFile = ProcessInfo.processInfo.environment["SHELLPANE_SSH_CONFIG"]
    let favorites: FavoritesStore
    let synclets: SyncletsStore
    let groups: GroupsStore
    let bookmarks: BookmarksStore
    let log: OperationLog
    let secrets: SecretStore
    /// Set when the database couldn't be opened; favorites then live in memory for this run.
    private(set) var storageProblem: String?

    /// SSH_AUTH_SOCK as your login shell sets it (so an agent configured in ~/.zshrc works from Finder).
    /// Read once, in the background, at launch; connects wait for it (at most a few seconds).
    private let shellEnvironment = Task.detached(priority: .userInitiated) { () -> [String: String] in
        guard ProcessInfo.processInfo.environment["SHELLPANE_SKIP_SHELL_ENV"] == nil else { return [:] }
        let env = ShellEnvironment.read(["SSH_AUTH_SOCK"])
        guard let sock = env["SSH_AUTH_SOCK"], FileManager.default.fileExists(atPath: sock) else { return [:] }
        return env
    }
    private var sessions: [String: RemoteSession] = [:]
    /// Connections still being opened: a second request for the same server waits for the first.
    private var opening: [String: Task<RemoteSession, Error>] = [:]
    private var contexts: [String: CredentialContext] = [:]
    private var askpass: AskpassServer?
    private let palette: [ConnectionColour] = [.blue, .green, .purple, .orange, .teal, .pink, .red]

    private init() {
        let env = ProcessInfo.processInfo.environment
        let keychain = KeychainStore(service: env["SHELLPANE_KEYCHAIN_SERVICE"] ?? "app.shellpane.credentials")
        secrets = keychain
        // Dev/demo only: seed a secret into a non-default Keychain service so a demo can log in without typing.
        // Ignored for the real service, so it can never touch a person's saved passwords.
        if keychain.service != "app.shellpane.credentials", let seed = env["SHELLPANE_DEMO_SEED_SECRET"],
           let eq = seed.firstIndex(of: "=") {
            try? keychain.setSecret(String(seed[seed.index(after: eq)...]), for: String(seed[..<eq]), label: "Shellpane demo")
        }
        let db: Database
        do {
            db = try Database(path: Database.defaultPath())
        } catch {
            storageProblem = error.localizedDescription
            db = try! Database(path: ":memory:")
        }
        favorites = FavoritesStore(database: db)
        synclets = SyncletsStore(database: db)
        groups = GroupsStore(database: db)
        bookmarks = BookmarksStore(database: db)
        log = OperationLog(database: db)
        log.prune(olderThanDays: 30)
    }

    var sshConfigHosts: [String] {
        SSHConfig.hosts(in: configFile.map { URL(fileURLWithPath: $0) } ?? SSHConfig.defaultURL)
    }

    func resolve(alias: String) async -> SSHConfig.Resolved? {
        let cfg = configFile
        return await Task.detached { try? SSHConfig.resolve(alias, configFile: cfg) }.value
    }

    // MARK: - Connecting

    /// A saved server. `typedPassword` comes from the Connect form; `savePassword` keeps it in Keychain once it works.
    func connect(_ favorite: Favorite, typedPassword: String? = nil, savePassword: Bool = false) async throws -> RemoteSession {
        // Already connected to this very server some other way (its ssh_config alias, a typed address): reuse it.
        if typedPassword == nil, let open = openSession(sameServerAs: favorite.target) {
            sessions[favorite.id] = open
            return open
        }
        return try await once(favorite.id) { try await self.openFavorite(favorite, typedPassword: typedPassword, savePassword: savePassword) }
    }

    /// A live session to the same ssh destination (host or alias, port, user, key).
    func openSession(sameServerAs target: SSHTarget) -> RemoteSession? {
        sessions.values.first { $0.isAlive && $0.target == target }
    }

    /// Saved servers that point at the same destination as `target` (so the sidebar can show them connected).
    func favorites(matching target: SSHTarget) -> [Favorite] {
        ((try? favorites.all()) ?? []).filter { $0.target == target }
    }

    /// One connection attempt per server at a time (double-clicks, two panes reconnecting at once).
    private func once(_ key: String, _ open: @escaping @MainActor () async throws -> RemoteSession) async throws -> RemoteSession {
        if let existing = sessions[key], existing.isAlive { return existing }
        if let pending = opening[key] { return try await pending.value }
        let task = Task { @MainActor in try await open() }
        opening[key] = task
        defer { opening[key] = nil }
        return try await task.value
    }

    private func openFavorite(_ favorite: Favorite, typedPassword: String?, savePassword: Bool) async throws -> RemoteSession {
        let context = CredentialContext(keychainRef: favorite.keychainRef, label: "Shellpane: \(favorite.name)",
                                        store: secrets, typedSecret: typedPassword)
        if savePassword, let typedPassword, !typedPassword.isEmpty { context.rememberAfterSuccess(typedPassword) }
        let colour = favorite.colour.flatMap(ConnectionColour.init(rawValue:)) ?? nextColour()
        let session = try await open(favorite.target, key: favorite.id, label: favorite.name,
                                     extraOptions: favorite.extraSSHOptions, context: context, colour: colour)
        try? context.connectionSucceeded()
        try? favorites.markUsed(id: favorite.id)
        let id = favorite.id
        session.reopen = { [unowned self] in
            // Re-read the favorite: it may have been edited since.
            let current = (try? self.favorites.favorite(id: id)) ?? nil
            return try await self.connect(current ?? favorite)
        }
        sessions[favorite.id] = session
        return session
    }

    /// A typed address or an ssh_config alias, not saved.
    func connect(_ target: SSHTarget) async throws -> RemoteSession {
        let key = "adhoc:" + target.displayName + ":" + String(target.port ?? 0)
        return try await once(key) { try await self.openTarget(target, key: key) }
    }

    private func openTarget(_ target: SSHTarget, key: String) async throws -> RemoteSession {
        let context = CredentialContext(keychainRef: nil, label: target.displayName, store: secrets)
        let session = try await open(target, key: key, label: target.host, extraOptions: [], context: context, colour: nextColour())
        session.reopen = { [unowned self] in try await self.connect(target) }
        sessions[key] = session
        return session
    }

    private func open(_ target: SSHTarget, key: String, label: String, extraOptions: [String], context: CredentialContext,
                      colour: ConnectionColour) async throws -> RemoteSession {
        guard let helper = SSHConnection.bundledAskpassHelper() else {
            throw SFTPError.connectionClosed(detail: "Shellpane is missing its password helper (shellpane-askpass). Reinstall the app.")
        }
        let server = try askpassServer()
        let token = UUID().uuidString
        contexts[token] = context
        defer { contexts[token] = nil }
        let client: SFTPClient
        do {
            client = try await SSHConnection.open(target, askpass: server, helper: helper, token: token,
                                                  configFile: configFile, extraOptions: extraOptions,
                                                  environment: await shellEnvironment.value)
        } catch {
            log.record(.connect, path: label, result: .failed, message: error.localizedDescription, favoriteID: key)
            throw error
        }
        log.record(.connect, path: label, message: target.displayName, favoriteID: key)
        let home = (try? await client.realpath(".")) ?? "/"
        return RemoteSession(key: key, label: label, target: target, client: client, colour: colour, home: home)
    }

    private func nextColour() -> ConnectionColour { palette[sessions.count % palette.count] }

    func isConnected(_ favoriteID: String) -> Bool { sessions[favoriteID]?.isAlive ?? false }

    func disconnect(_ favoriteID: String) {
        if let s = sessions.removeValue(forKey: favoriteID) {
            s.client.close()
            log.record(.disconnect, path: s.label, favoriteID: favoriteID)
        }
    }

    /// What Shellpane found in the login shell, for Settings and diagnostics.
    func shellAgentSocket() async -> String? { await shellEnvironment.value["SSH_AUTH_SOCK"] }

    func closeAll() {
        for s in sessions.values { s.client.close() }
        sessions.removeAll()
    }

    // MARK: - Saved servers

    /// Saves a favorite. A new password is stored only after it has worked (see CredentialContext).
    func save(_ favorite: Favorite) throws {
        try favorites.save(favorite)
    }

    func delete(_ favorite: Favorite) throws {
        disconnect(favorite.id)
        if let ref = favorite.keychainRef { try? secrets.deleteSecret(for: ref) }
        try favorites.delete(id: favorite.id)
    }

    /// Main-thread Keychain read: only for the Edit form, where it's one quick lookup the person asked for.
    func hasSavedSecret(_ favorite: Favorite) -> Bool {
        guard let ref = favorite.keychainRef else { return false }
        return ((try? secrets.secret(for: ref)) ?? nil) != nil
    }

    func forgetSecret(_ favorite: Favorite) {
        if let ref = favorite.keychainRef { try? secrets.deleteSecret(for: ref) }
    }

    // MARK: - Askpass

    func context(for token: String?) -> CredentialContext? {
        token.flatMap { contexts[$0] }
    }

    private func askpassServer() throws -> AskpassServer {
        if let askpass { return askpass }
        let server = try AskpassServer { request in await Prompter.answer(request) }
        askpass = server
        return server
    }
}

/// Shows ssh's questions as native alerts. Our words, not ssh's, with ssh's text kept for reference.
@MainActor
enum Prompter {
    /// Self-test only: answers prompts without dialogs, and records the ones that reached the "person"
    /// (not those Shellpane answered itself from the form or Keychain).
    static var testAnswer: ((AskpassRequest, CredentialContext?) -> String?)?
    static var testLog: [AskpassRequest] = []

    static func answer(_ request: AskpassRequest) async -> String? {
        let context = ConnectionManager.shared.context(for: request.token)
        if let context {
            // Off the main thread: a Keychain read can block on a system prompt or a locked keychain.
            let decision = await Task.detached(priority: .userInitiated) { context.decide(request) }.value
            if case let .answer(secret) = decision { return secret }
        }
        if let testAnswer {
            testLog.append(request)
            let answer = testAnswer(request, context)
            if request.kind == .secret, let answer, context?.keychainRef != nil { context?.rememberAfterSuccess(answer) }
            return answer
        }
        switch request.kind {
        case .hostKey: return await hostKey(request)
        case .secret: return await secret(request, context: context)
        case .confirm: return await confirm(request) ? "yes" : nil
        case .notice: return ""
        }
    }

    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible), window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    /// "The authenticity of host '[127.0.0.1]:2222 ([127.0.0.1]:2222)' can't be established." -> "[127.0.0.1]:2222"
    static func hostName(in prompt: String) -> String {
        guard let start = prompt.firstIndex(of: "'"), let end = prompt[prompt.index(after: start)...].firstIndex(of: "'") else {
            return "this server"
        }
        let inner = prompt[prompt.index(after: start)..<end]
        return String(inner.split(separator: " ").first ?? inner)
    }

    private static func hostKey(_ request: AskpassRequest) async -> String? {
        let host = hostName(in: request.prompt)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "First time connecting to \(host)"
        alert.informativeText = """
        You haven't connected to this server from this Mac before. If you have its fingerprint, check it matches:

        \(request.fingerprint ?? "(ssh didn't show a fingerprint)")

        Shellpane adds it to ~/.ssh/known_hosts, the same file ssh uses, and refuses to connect if it ever changes.
        """
        alert.addButton(withTitle: "Trust and Connect")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return await present(alert) == .alertFirstButtonReturn ? "yes" : "no"
    }

    private static func secret(_ request: AskpassRequest, context: CredentialContext?) async -> String? {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        let retry = context?.savedSecretWasRejected == true
        if let r = prompt.range(of: #"passphrase for key '([^']+)'"#, options: [.regularExpression, .caseInsensitive]) {
            let path = prompt[r].split(separator: "'").dropFirst().first.map(String.init) ?? ""
            alert.messageText = "Unlock key “\((path as NSString).lastPathComponent)”"
            alert.informativeText = retry ? "The saved passphrase didn't work. Enter the passphrase for \(path)."
                                          : "Enter the passphrase for \(path)."
        } else if prompt.lowercased().hasSuffix("password:") {
            let who = prompt.replacingOccurrences(of: "'s password:", with: "")
            alert.messageText = "Password for \(who)"
            alert.informativeText = retry ? "The saved password didn't work. Enter it again." : "The server is asking for your password."
        } else {
            alert.messageText = "The server is asking for more information"
            alert.informativeText = prompt
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Required"
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        stack.addArrangedSubview(field)
        let save = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        save.state = .on
        if context?.keychainRef != nil { stack.addArrangedSubview(save) }
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: context?.keychainRef != nil ? 52 : 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        if save.state == .on, let context { context.rememberAfterSuccess(field.stringValue) }
        return field.stringValue
    }

    private static func confirm(_ request: AskpassRequest) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow this?"
        alert.informativeText = request.prompt
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return await present(alert) == .alertFirstButtonReturn
    }
}
