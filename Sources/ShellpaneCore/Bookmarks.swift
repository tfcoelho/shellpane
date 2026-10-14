import Foundation

/// A favorite folder: a path on this Mac, on a saved server, or on a ~/.ssh/config host.
public struct Bookmark: Identifiable, Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        case local
        case favorite(String)   // a saved server's id
        case sshAlias(String)   // a Host from ~/.ssh/config that isn't saved
    }

    public var id: String
    public var name: String
    public var place: Place
    public var path: String
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, name: String, place: Place, path: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.place = place
        self.path = path
        self.sortOrder = sortOrder
    }

    /// The name a new favorite folder gets: the folder's own name ("/" for the top).
    public static func defaultName(for path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? "/" : last
    }
}

public final class BookmarksStore: @unchecked Sendable {
    private let db: Database

    public init(database: Database) { self.db = database }

    public func all() throws -> [Bookmark] {
        try db.query("SELECT * FROM bookmarks ORDER BY sort_order, name COLLATE NOCASE").map { row in
            let place: Bookmark.Place
            if let fav = row["favorite_id"]?.string { place = .favorite(fav) }
            else if let alias = row["ssh_alias"]?.string { place = .sshAlias(alias) }
            else { place = .local }
            return Bookmark(id: row["id"]?.string ?? "", name: row["name"]?.string ?? "", place: place,
                            path: row["path"]?.string ?? "/", sortOrder: Int(row["sort_order"]?.int ?? 0))
        }
    }

    /// Adds a folder at the end of the list. The same folder added twice is kept once.
    @discardableResult
    public func add(name: String? = nil, place: Bookmark.Place, path: String) throws -> Bookmark {
        guard path.hasPrefix("/") else { throw Favorite.ValidationError.missingServer }
        if let existing = try find(place: place, path: path) { return existing }
        let trimmed = (name ?? Bookmark.defaultName(for: path)).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Favorite.ValidationError.missingName }
        let next = Int(try db.query("SELECT COALESCE(MAX(sort_order), 0) + 1 AS n FROM bookmarks").first?["n"]?.int ?? 1)
        let b = Bookmark(name: trimmed, place: place, path: path, sortOrder: next)
        try db.execute("INSERT INTO bookmarks (id, name, favorite_id, ssh_alias, path, sort_order) VALUES (?, ?, ?, ?, ?, ?)",
                       [.text(b.id), .text(b.name), Self.favoriteID(place).sql, Self.alias(place).sql, .text(path), .int(Int64(next))])
        return b
    }

    public func find(place: Bookmark.Place, path: String) throws -> Bookmark? {
        try all().first { $0.place == place && $0.path == path }
    }

    public func rename(_ id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Favorite.ValidationError.missingName }
        try db.execute("UPDATE bookmarks SET name = ?, updated_at = unixepoch() WHERE id = ?", [.text(trimmed), .text(id)])
    }

    public func delete(_ id: String) throws {
        try db.execute("DELETE FROM bookmarks WHERE id = ?", [.text(id)])
    }

    private static func favoriteID(_ p: Bookmark.Place) -> String? { if case let .favorite(id) = p { id } else { nil } }
    private static func alias(_ p: Bookmark.Place) -> String? { if case let .sshAlias(a) = p { a } else { nil } }
}
