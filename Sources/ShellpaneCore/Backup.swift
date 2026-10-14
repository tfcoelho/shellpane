import Foundation
import TransferKit

/// Servers, groups and saved syncs as a file, to back up or move to another Mac.
/// Never contains passwords, passphrases or Keychain references: those stay in this Mac's Keychain,
/// and the new Mac asks once on first connect.
public struct Backup: Codable, Equatable {
    public struct Group: Codable, Equatable { var id: String; var name: String }
    public struct Server: Codable, Equatable {
        var id: String; var groupID: String?; var name: String; var sshAlias: String?; var host: String?
        var port: Int?; var username: String?; var auth: String; var keyPath: String?; var initialPath: String?; var colour: String?
        var icon: String?   // added after the first backups; absent in older files
    }
    public struct Sync: Codable, Equatable {
        var id: String; var name: String; var leftServerID: String?; var leftPath: String
        var rightServerID: String?; var rightPath: String; var options: SyncOptions
    }

    public var format = "shellpane-backup"
    public var version = 1
    public var groups: [Group] = []
    public var servers: [Server] = []
    public var syncs: [Sync] = []

    public struct ImportResult: Equatable { public var groups = 0; public var servers = 0; public var syncs = 0; public var skipped = 0 }
}

public enum BackupIO {
    public static func export(favorites: FavoritesStore, groups: GroupsStore, synclets: SyncletsStore) throws -> Data {
        var b = Backup()
        b.groups = try groups.all().map { .init(id: $0.id, name: $0.name) }
        b.servers = try favorites.all().map {
            .init(id: $0.id, groupID: $0.groupID, name: $0.name, sshAlias: $0.sshAlias, host: $0.host, port: $0.port,
                  username: $0.username, auth: $0.auth.rawValue, keyPath: $0.keyPath, initialPath: $0.initialPath, colour: $0.colour,
                  icon: $0.icon)
        }
        b.syncs = try synclets.all().map {
            .init(id: $0.id, name: $0.name, leftServerID: $0.leftFavoriteID, leftPath: $0.leftPath,
                  rightServerID: $0.rightFavoriteID, rightPath: $0.rightPath, options: $0.options)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(b)
    }

    /// Adds what isn't there yet. A server with the same name and destination counts as already there.
    public static func importBackup(_ data: Data, favorites: FavoritesStore, groups: GroupsStore,
                                    synclets: SyncletsStore) throws -> Backup.ImportResult {
        let b = try JSONDecoder().decode(Backup.self, from: data)
        guard b.format == "shellpane-backup", b.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        var result = Backup.ImportResult()
        var groupMap: [String: String] = [:]
        let existingGroups = try groups.all()
        for g in b.groups {
            if let same = existingGroups.first(where: { $0.name == g.name }) { groupMap[g.id] = same.id; continue }
            groupMap[g.id] = try groups.create(g.name).id
            result.groups += 1
        }
        var serverMap: [String: String] = [:]
        let existing = try favorites.all()
        for s in b.servers {
            var f = Favorite(name: s.name, sshAlias: s.sshAlias, host: s.host, port: s.port, username: s.username,
                             auth: AuthMethod(rawValue: s.auth) ?? .auto, keyPath: s.keyPath,
                             keychainRef: UUID().uuidString, initialPath: s.initialPath, colour: s.colour, icon: s.icon)
            f.groupID = s.groupID.flatMap { groupMap[$0] }
            if let same = existing.first(where: { $0.name == f.name && $0.target == f.target }) {
                serverMap[s.id] = same.id
                result.skipped += 1
                continue
            }
            try favorites.save(f)
            serverMap[s.id] = f.id
            result.servers += 1
        }
        let existingSyncs = try synclets.all()
        for y in b.syncs {
            if existingSyncs.contains(where: { $0.name == y.name && $0.leftPath == y.leftPath && $0.rightPath == y.rightPath }) {
                result.skipped += 1
                continue
            }
            try synclets.save(Synclet(name: y.name, leftFavoriteID: y.leftServerID.flatMap { serverMap[$0] }, leftPath: y.leftPath,
                                      rightFavoriteID: y.rightServerID.flatMap { serverMap[$0] }, rightPath: y.rightPath, options: y.options))
            result.syncs += 1
        }
        return result
    }
}
