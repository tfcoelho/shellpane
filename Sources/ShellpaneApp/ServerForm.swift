import AppKit
import Combine
import ShellpaneCore
import ShellpaneUI
import SSHProcess
import SwiftUI

/// S03 Connect panel and S05 Edit server: one form, two modes.
@MainActor
final class ServerFormModel: ObservableObject {
    enum Mode: Equatable {
        case connect
        case edit(Favorite)
    }

    let mode: Mode
    let configHosts: [String]
    let foundKeys: [String]
    @Published var name = ""
    @Published var sshAlias = ""            // "" = typed address
    @Published var server = ""
    @Published var port = ""
    @Published var username = ""
    @Published var auth: AuthMethod = .auto
    @Published var password = ""
    @Published var savePassword = true
    @Published var keyPath = ""
    @Published var initialPath = ""
    @Published var colour: ConnectionColour = .blue
    @Published var icon: String = ServerIcons.standard
    @Published var groupID = ""   // "" = no group
    let groups: [FavoriteGroup] = (try? ConnectionManager.shared.groups.all()) ?? []
    @Published var saveAsFavorite = true
    @Published var errors: [Favorite.ValidationError] = []
    @Published var resolved: SSHConfig.Resolved?
    @Published var hasSavedPassword = false
    @Published var forgetSavedPassword = false

    var onSubmit: (Favorite, _ password: String?, _ savePassword: Bool, _ saveAsFavorite: Bool) -> Void = { _, _, _, _ in }
    var onCancel: () -> Void = {}
    var onDelete: (Favorite) -> Void = { _ in }
    private var nameEdited = false

    /// What the sidebar row will say: the name, else the host as typed or picked.
    var previewName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        if !sshAlias.isEmpty { return sshAlias }
        let typed = server.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? "New server" : typed
    }

    init(mode: Mode, configHosts: [String], prefillAlias: String? = nil) {
        self.mode = mode
        self.configHosts = configHosts
        self.foundKeys = Self.findKeys()
        if case let .edit(f) = mode {
            name = f.name
            sshAlias = f.sshAlias ?? ""
            server = f.host ?? ""
            port = f.port.map(String.init) ?? ""
            username = f.username ?? ""
            auth = f.auth
            keyPath = f.keyPath ?? ""
            initialPath = f.initialPath ?? ""
            colour = f.colour.flatMap(ConnectionColour.init(rawValue:)) ?? .blue
            icon = ServerIcons.resolve(f.icon)
            groupID = f.groupID ?? ""
            hasSavedPassword = ConnectionManager.shared.hasSavedSecret(f)
            nameEdited = true
            if f.sshAlias != nil { resolveAlias() }
        } else if let prefillAlias {
            pickAlias(prefillAlias)
        }
    }

    var isEdit: Bool { if case .edit = mode { return true }; return false }

    /// Private keys in ~/.ssh: by file name only, contents never read.
    static func findKeys() -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { n in
            (n.hasPrefix("id_") || n.hasSuffix(".pem") || n.hasSuffix(".key")) && !n.hasSuffix(".pub")
        }.sorted().map { "~/.ssh/" + $0 }
    }

    func pickAlias(_ alias: String) {
        sshAlias = alias
        if !nameEdited || name.isEmpty { name = alias }
        resolveAlias()
    }

    func nameChanged() { nameEdited = !name.isEmpty }

    private func resolveAlias() {
        let alias = sshAlias
        resolved = nil
        guard !alias.isEmpty else { return }
        Task { @MainActor in
            let r = await ConnectionManager.shared.resolve(alias: alias)
            if self.sshAlias == alias { self.resolved = r }
        }
    }

    /// "deploy@web-1.example.com:2222" typed into Server fills Username and Port.
    func serverCommitted() {
        guard server.contains("@") || server.contains(":") || server.contains("://"),
              let t = SSHTarget(parsing: server) else { return }
        server = t.host
        if let u = t.user { username = u }
        if let p = t.port { port = String(p) }
        if !nameEdited || name.isEmpty { name = t.host }
    }

    func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a private key"
        panel.message = "Pick the private key file (not the .pub one)."
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        }
    }

    func submit() {
        if !server.isEmpty { serverCommitted() }
        var f: Favorite
        if case let .edit(existing) = mode { f = existing } else { f = Favorite(name: name) }
        f.name = name.isEmpty ? (sshAlias.isEmpty ? server : sshAlias) : name
        f.sshAlias = sshAlias.isEmpty ? nil : sshAlias
        f.host = sshAlias.isEmpty ? server : nil
        let portText = port.trimmingCharacters(in: .whitespaces)
        f.port = portText.isEmpty ? nil : (Int(portText) ?? -1)
        // Empty means "let ssh decide" (ssh_config's User, or the Mac's user), never `-l ''`.
        let user = username.trimmingCharacters(in: .whitespaces)
        f.username = user.isEmpty ? nil : user
        f.auth = auth
        f.keyPath = auth == .key ? keyPath : nil
        f.initialPath = initialPath
        f.colour = colour.rawValue
        f.icon = icon
        f.groupID = groupID.isEmpty ? nil : groupID
        let storing = isEdit || saveAsFavorite
        if storing && f.keychainRef == nil && (auth == .password || auth == .auto || auth == .key) {
            f.keychainRef = UUID().uuidString  // where a password or passphrase will go, if one is ever saved
        }
        errors = f.validate()
        guard errors.isEmpty else { NSSound.beep(); return }
        if isEdit && forgetSavedPassword { ConnectionManager.shared.forgetSecret(f) }
        onSubmit(f, auth == .password && !password.isEmpty ? password : nil, storing && savePassword, storing)
    }
}

struct ServerFormView: View {
    @ObservedObject var model: ServerFormModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                serverSection
                appearanceSection
                loginSection
                optionsSection
                if !model.errors.isEmpty {
                    Section {
                        ForEach(model.errors, id: \.self) { e in
                            Label(e.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Tokens.Colors.danger)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(false)
            footer
        }
        .frame(width: Tokens.Size.sheetWidth + 60)
        .frame(minHeight: 640)
    }

    /// The server as the sidebar will show it, updating as you type and pick.
    private var header: some View {
        HStack(spacing: Tokens.Space.s16) {
            ServerBadge(icon: model.icon, colour: model.colour, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isEdit ? "Edit Server" : "Connect to a Server")
                    .font(.title3.weight(.semibold))
                Text(model.previewName)
                    .foregroundStyle(Tokens.Colors.textMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding([.horizontal, .top], Tokens.Space.s24)
        .padding(.bottom, Tokens.Space.s4)
    }

    private var appearanceSection: some View {
        Section {
            LabeledContent("Colour") {
                HStack(spacing: Tokens.Space.s8) {
                    ForEach(ConnectionColour.allCases.filter { $0 != .none }, id: \.self) { c in
                        Button { model.colour = c } label: {
                            ZStack {
                                Circle().fill(c.color).frame(width: 16, height: 16)
                                if model.colour == c {
                                    Circle().strokeBorder(Tokens.Colors.text, lineWidth: 2).frame(width: 22, height: 22)
                                }
                            }
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(c.rawValue.capitalized)
                        .accessibilityLabel(c.rawValue.capitalized)
                        .accessibilityAddTraits(model.colour == c ? .isSelected : [])
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: Tokens.Space.s8), count: 8),
                      spacing: Tokens.Space.s8) {
                ForEach(ServerIcons.all, id: \.self) { name in
                    Button { model.icon = name } label: {
                        // Line icons as in Finder; the chosen one in its colour with a thin ring, no fill.
                        let chosen = model.icon == name
                        Image(systemName: name)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(chosen ? model.colour.color : Tokens.Colors.textMuted)
                            .frame(width: 32, height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(chosen ? model.colour.color : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
                    .accessibilityAddTraits(model.icon == name ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.Space.s4)
        } header: {
            Text("Appearance")
        } footer: {
            Text("How it looks in the sidebar and on the path bar's server bar.")
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textMuted)
        }
    }

    private var serverSection: some View {
        Section {
            if !model.configHosts.isEmpty {
                Picker("From SSH config", selection: Binding(get: { model.sshAlias }, set: { v in
                    if v.isEmpty { model.sshAlias = ""; model.resolved = nil } else { model.pickAlias(v) }
                })) {
                    Text("None: type an address").tag("")
                    Divider()
                    ForEach(model.configHosts, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Name", text: Binding(get: { model.name }, set: { model.name = $0; model.nameChanged() }),
                      prompt: Text("Production web"))
            if model.sshAlias.isEmpty {
                TextField("Server", text: $model.server, prompt: Text("deploy@example.com:22"))
                    .onSubmit { model.serverCommitted() }
                    .help("You can type user@server:port and Shellpane fills in the rest")
            } else {
                LabeledContent("Resolves to") {
                    if let r = model.resolved {
                        Text(verbatim: "\(r.user)@\(r.hostname):\(r.port)" + (r.proxyJump.map { " via \($0)" } ?? ""))
                            .font(.callout.monospaced())
                            .foregroundStyle(Tokens.Colors.textMuted)
                            .textSelection(.enabled)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            TextField("Port", text: $model.port, prompt: Text(model.sshAlias.isEmpty ? "22" : "from SSH config"))
            TextField("Username", text: $model.username, prompt: Text(model.sshAlias.isEmpty ? Recording.userName : "from SSH config"))
        } header: {
            Text("Server")
        }
    }

    private var loginSection: some View {
        Section {
            Picker("Authentication", selection: $model.auth) {
                ForEach(AuthMethod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            switch model.auth {
            case .password:
                SecureField("Password", text: $model.password,
                            prompt: Text(model.hasSavedPassword ? "Saved in Keychain" : "Asked when connecting if empty"))
                if !model.isEdit {
                    Toggle("Remember in Keychain", isOn: $model.savePassword)
                        .disabled(!model.saveAsFavorite)
                }
            case .key:
                LabeledContent("Key file") {
                    HStack {
                        TextField("Key file", text: $model.keyPath, prompt: Text("~/.ssh/id_ed25519"))
                            .labelsHidden()
                            .font(.callout.monospaced())
                        if !model.foundKeys.isEmpty {
                            Menu {
                                ForEach(model.foundKeys, id: \.self) { k in Button(k) { model.keyPath = k } }
                            } label: {
                                Image(systemName: "key")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Keys found in ~/.ssh")
                        }
                        Button("Choose…") { model.chooseKeyFile() }
                    }
                }
                Text("If the key has a passphrase, Shellpane asks for it when connecting and can remember it in Keychain.")
                    .font(.callout)
                    .foregroundStyle(Tokens.Colors.textMuted)
            case .auto, .agent:
                Text(model.auth == .auto
                     ? "Uses your SSH config, your SSH agent (including 1Password or Secretive) and your default keys, the same as ssh in Terminal."
                     : "Only keys held by your SSH agent are tried.")
                    .font(.callout)
                    .foregroundStyle(Tokens.Colors.textMuted)
            }
            if model.isEdit && model.hasSavedPassword {
                Toggle("Forget the saved password or passphrase", isOn: $model.forgetSavedPassword)
            }
        } header: {
            Text("Login")
        }
    }

    private var optionsSection: some View {
        Section {
            TextField("Open at folder", text: $model.initialPath, prompt: Text("Home folder"))
            if !model.groups.isEmpty {
                Picker("Group", selection: $model.groupID) {
                    Text("None").tag("")
                    ForEach(model.groups) { Text($0.name).tag($0.id) }
                }
            }
        } header: {
            Text("Options")
        }
    }

    private var footer: some View {
        HStack {
            if case let .edit(f) = model.mode {
                Button("Delete…", role: .destructive) { model.onDelete(f) }
            } else {
                Toggle("Save as favorite", isOn: $model.saveAsFavorite)
            }
            Spacer()
            Button("Cancel") { model.onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(model.isEdit ? "Save" : "Connect") { model.submit() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Tokens.Space.s16)
    }
}
