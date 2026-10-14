import Foundation
import SSHProcess

public enum AuthMethod: String, Sendable, CaseIterable, Codable {
    /// Whatever ~/.ssh/config and the agent offer. The default, and right for most people.
    case auto
    case password
    case key
    case agent

    public var title: String {
        switch self {
        case .auto: "Automatic (SSH config & agent)"
        case .password: "Password"
        case .key: "Key file"
        case .agent: "SSH agent only"
        }
    }
}

/// A saved server. Colour is a role name ("blue"); ShellpaneUI maps it to a colour.
public struct Favorite: Identifiable, Equatable, Sendable {
    public var id: String
    public var groupID: String?
    public var name: String
    public var sshAlias: String?
    public var host: String?
    public var port: Int?
    public var username: String?
    public var auth: AuthMethod
    public var keyPath: String?
    public var keychainRef: String?
    public var initialPath: String?
    public var colour: String?
    /// The sidebar icon: an SF Symbol name from the form's picker. nil = the default server icon.
    public var icon: String?
    public var sortOrder: Int
    public var lastUsedAt: Date?

    public init(id: String = UUID().uuidString, groupID: String? = nil, name: String, sshAlias: String? = nil,
                host: String? = nil, port: Int? = nil, username: String? = nil, auth: AuthMethod = .auto,
                keyPath: String? = nil, keychainRef: String? = nil, initialPath: String? = nil,
                colour: String? = nil, icon: String? = nil, sortOrder: Int = 0, lastUsedAt: Date? = nil) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.sshAlias = sshAlias
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.keyPath = keyPath
        self.keychainRef = keychainRef
        self.initialPath = initialPath
        self.colour = colour
        self.icon = icon
        self.sortOrder = sortOrder
        self.lastUsedAt = lastUsedAt
    }

    /// What ssh is told. An alias lets ssh_config fill in everything not overridden here.
    public var target: SSHTarget {
        SSHTarget(host: sshAlias ?? host ?? "", port: port, user: username.nilIfEmpty,
                  identityFile: auth == .key ? keyPath : nil)
    }

    public var extraSSHOptions: [String] {
        switch auth {
        case .password: ["-oPreferredAuthentications=password,keyboard-interactive", "-oPubkeyAuthentication=no"]
        case .agent: ["-oIdentitiesOnly=no", "-oPreferredAuthentications=publickey"]
        case .auto, .key: []
        }
    }

    public var subtitle: String {
        if let sshAlias, host == nil, username == nil, port == nil { return "~/.ssh/config: \(sshAlias)" }
        var s = target.displayName
        if let port, port != 22 { s += ":\(port)" }
        return s
    }

    public enum ValidationError: Error, Hashable, LocalizedError {
        case missingName, missingServer, unsafeServer, unsafeUser, badPort, missingKey, keyNotFound(String), badIcon

        public var errorDescription: String? {
            switch self {
            case .missingName: "Give the server a name."
            case .missingServer: "Enter a server address, or pick a host from your SSH config."
            case .unsafeServer: "That server address has characters SSH won't accept."
            case .unsafeUser: "That username has characters SSH won't accept."
            case .badPort: "The port must be a number from 1 to 65535."
            case .missingKey: "Choose a key file, or switch Authentication to Automatic."
            case let .keyNotFound(path): "There's no key file at \(path)."
            case .badIcon: "Choose an icon from the list."
            }
        }
    }

    public func validate(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }) -> [ValidationError] {
        var errors: [ValidationError] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.missingName) }
        let server = sshAlias ?? host ?? ""
        if server.isEmpty { errors.append(.missingServer) } else if !SSHTarget.isSafe(host: server) { errors.append(.unsafeServer) }
        if let user = username.nilIfEmpty, !SSHTarget.isSafe(user: user) { errors.append(.unsafeUser) }
        if let port, !(1...65535).contains(port) { errors.append(.badPort) }
        // Same rule as the database's: a short symbol name, lowercase letters, digits and dots.
        if let icon, icon.isEmpty || icon.count > 64 || icon.contains(where: { !($0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".")) }) {
            errors.append(.badIcon)
        }
        if auth == .key {
            if let keyPath, !keyPath.isEmpty {
                if !fileExists(keyPath) { errors.append(.keyNotFound(keyPath)) }
            } else {
                errors.append(.missingKey)
            }
        }
        return errors
    }
}

/// CRUD for saved servers. The secret behind keychainRef is the caller's to manage via SecretStore.
public final class FavoritesStore: @unchecked Sendable {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    public func all() throws -> [Favorite] {
        try db.query("SELECT * FROM favorites ORDER BY sort_order, name COLLATE NOCASE").map(Self.decode)
    }

    public func favorite(id: String) throws -> Favorite? {
        try db.query("SELECT * FROM favorites WHERE id = ?", [.text(id)]).first.map(Self.decode)
    }

    /// Insert or update. New favorites go to the end of the list.
    public func save(_ f: Favorite) throws {
        let errors = f.validate(fileExists: { _ in true })  // key existence is a UI warning, not a storage rule
        if let first = errors.first { throw first }
        try db.transaction {
            var fav = f
            if try favorite(id: f.id) == nil, f.sortOrder == 0 {
                let maxOrder = try db.query("SELECT COALESCE(MAX(sort_order), 0) AS m FROM favorites").first?["m"]?.int ?? 0
                fav.sortOrder = Int(maxOrder) + 1
            }
            try db.execute("""
                INSERT INTO favorites (id, group_id, name, protocol, ssh_alias, host, port, username, auth,
                                       key_path, keychain_ref, initial_path, colour, icon, sort_order, last_used_at)
                VALUES (?, ?, ?, 'sftp', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  group_id = excluded.group_id, name = excluded.name, ssh_alias = excluded.ssh_alias,
                  host = excluded.host, port = excluded.port, username = excluded.username, auth = excluded.auth,
                  key_path = excluded.key_path, keychain_ref = excluded.keychain_ref,
                  initial_path = excluded.initial_path, colour = excluded.colour, icon = excluded.icon,
                  sort_order = excluded.sort_order,
                  updated_at = unixepoch()
                """, [
                    .text(fav.id), fav.groupID.sql, .text(fav.name.trimmingCharacters(in: .whitespaces)),
                    fav.sshAlias.nilIfEmpty.sql, fav.host.nilIfEmpty.sql, fav.port.sql, fav.username.nilIfEmpty.sql,
                    .text(fav.auth.rawValue), fav.keyPath.nilIfEmpty.sql, fav.keychainRef.sql,
                    fav.initialPath.nilIfEmpty.sql, fav.colour.sql, fav.icon.sql, .int(Int64(fav.sortOrder)),
                    fav.lastUsedAt.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null,
                ])
        }
    }

    public func delete(id: String) throws {
        try db.execute("DELETE FROM favorites WHERE id = ?", [.text(id)])
    }

    public func markUsed(id: String, at date: Date = Date()) throws {
        try db.execute("UPDATE favorites SET last_used_at = ? WHERE id = ?", [.int(Int64(date.timeIntervalSince1970)), .text(id)])
    }

    public func move(id: String, toIndex index: Int) throws {
        var list = try all()
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: max(0, min(index, list.count)))
        try db.transaction {
            for (i, f) in list.enumerated() {
                try db.execute("UPDATE favorites SET sort_order = ? WHERE id = ?", [.int(Int64(i + 1)), .text(f.id)])
            }
        }
    }

    static func decode(_ row: [String: SQLValue]) -> Favorite {
        Favorite(id: row["id"]?.string ?? "",
                 groupID: row["group_id"]?.string,
                 name: row["name"]?.string ?? "",
                 sshAlias: row["ssh_alias"]?.string,
                 host: row["host"]?.string,
                 port: row["port"]?.int.map(Int.init),
                 username: row["username"]?.string,
                 auth: AuthMethod(rawValue: row["auth"]?.string ?? "auto") ?? .auto,
                 keyPath: row["key_path"]?.string,
                 keychainRef: row["keychain_ref"]?.string,
                 initialPath: row["initial_path"]?.string,
                 colour: row["colour"]?.string,
                 icon: row["icon"]?.string,
                 sortOrder: Int(row["sort_order"]?.int ?? 0),
                 lastUsedAt: row["last_used_at"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
