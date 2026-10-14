import Foundation

/// Sidebar folders for saved servers ("Clients", "Staging"…). Deleting one keeps its servers, ungrouped.
public struct FavoriteGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

public final class GroupsStore: @unchecked Sendable {
    private let db: Database

    public init(database: Database) { self.db = database }

    public func all() throws -> [FavoriteGroup] {
        try db.query("SELECT * FROM favorite_groups ORDER BY sort_order, name COLLATE NOCASE").map {
            FavoriteGroup(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "", sortOrder: Int($0["sort_order"]?.int ?? 0))
        }
    }

    @discardableResult
    public func create(_ name: String) throws -> FavoriteGroup {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Favorite.ValidationError.missingName }
        let next = Int(try db.query("SELECT COALESCE(MAX(sort_order), 0) + 1 AS n FROM favorite_groups").first?["n"]?.int ?? 1)
        let g = FavoriteGroup(name: trimmed, sortOrder: next)
        try db.execute("INSERT INTO favorite_groups (id, name, sort_order) VALUES (?, ?, ?)", [.text(g.id), .text(g.name), .int(Int64(next))])
        return g
    }

    public func rename(_ id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Favorite.ValidationError.missingName }
        try db.execute("UPDATE favorite_groups SET name = ?, updated_at = unixepoch() WHERE id = ?", [.text(trimmed), .text(id)])
    }

    public func delete(_ id: String) throws {
        try db.execute("DELETE FROM favorite_groups WHERE id = ?", [.text(id)])  // favorites.group_id → NULL (schema)
    }

    /// Puts a server in a group, or takes it out (nil).
    public func move(favorite id: String, to group: String?) throws {
        try db.execute("UPDATE favorites SET group_id = ?, updated_at = unixepoch() WHERE id = ?", [group.sql, .text(id)])
    }
}
