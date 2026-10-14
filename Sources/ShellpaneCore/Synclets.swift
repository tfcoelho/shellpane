import Foundation
import TransferKit

/// A saved sync. Each side is a local folder (favoriteID nil) or a folder on a saved server.
public struct Synclet: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var leftFavoriteID: String?
    public var leftPath: String
    public var rightFavoriteID: String?
    public var rightPath: String
    public var options: SyncOptions

    public init(id: String = UUID().uuidString, name: String, leftFavoriteID: String?, leftPath: String,
                rightFavoriteID: String?, rightPath: String, options: SyncOptions) {
        self.id = id
        self.name = name
        self.leftFavoriteID = leftFavoriteID
        self.leftPath = leftPath
        self.rightFavoriteID = rightFavoriteID
        self.rightPath = rightPath
        self.options = options
    }
}

public final class SyncletsStore: @unchecked Sendable {
    private let db: Database

    public init(database: Database) { self.db = database }

    public func all() throws -> [Synclet] {
        try db.query("SELECT * FROM synclets ORDER BY name COLLATE NOCASE").map(Self.decode)
    }

    public func save(_ s: Synclet) throws {
        guard s.options.isValid else { throw SyncError.twoWayDelete }
        let o = s.options
        let excludes = String(decoding: try JSONEncoder().encode(o.excludes), as: UTF8.self)
        try db.execute("""
            INSERT INTO synclets (id, name, left_favorite_id, left_path, right_favorite_id, right_path, direction,
                                  subfolders, include_hidden, add_missing, skip_empty_dirs, update_by, delete_orphans,
                                  time_offset_s, excludes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name, left_favorite_id = excluded.left_favorite_id, left_path = excluded.left_path,
              right_favorite_id = excluded.right_favorite_id, right_path = excluded.right_path,
              direction = excluded.direction, subfolders = excluded.subfolders, include_hidden = excluded.include_hidden,
              add_missing = excluded.add_missing, skip_empty_dirs = excluded.skip_empty_dirs, update_by = excluded.update_by,
              delete_orphans = excluded.delete_orphans, time_offset_s = excluded.time_offset_s, excludes = excluded.excludes,
              updated_at = unixepoch()
            """, [
                .text(s.id), .text(s.name), s.leftFavoriteID.sql, .text(s.leftPath), s.rightFavoriteID.sql, .text(s.rightPath),
                .text(o.direction.rawValue), .int(o.subfolders ? 1 : 0), .int(o.includeHidden ? 1 : 0), .int(o.addMissing ? 1 : 0),
                .int(o.skipEmptyFolders ? 1 : 0), .text(o.updateBy.rawValue), .int(o.deleteOrphans ? 1 : 0),
                .int(Int64(o.timeOffset)), .text(excludes),
            ])
    }

    public func delete(id: String) throws {
        try db.execute("DELETE FROM synclets WHERE id = ?", [.text(id)])
    }

    static func decode(_ row: [String: SQLValue]) -> Synclet {
        var o = SyncOptions()
        o.direction = SyncOptions.Direction(rawValue: row["direction"]?.string ?? "") ?? .leftToRight
        o.subfolders = row["subfolders"]?.int != 0
        o.includeHidden = row["include_hidden"]?.int == 1
        o.addMissing = row["add_missing"]?.int != 0
        o.skipEmptyFolders = row["skip_empty_dirs"]?.int == 1
        o.updateBy = SyncOptions.UpdateBy(rawValue: row["update_by"]?.string ?? "") ?? .date
        o.deleteOrphans = row["delete_orphans"]?.int == 1
        o.timeOffset = Int(row["time_offset_s"]?.int ?? 0)
        o.excludes = (row["excludes"]?.string?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return Synclet(id: row["id"]?.string ?? "", name: row["name"]?.string ?? "",
                       leftFavoriteID: row["left_favorite_id"]?.string, leftPath: row["left_path"]?.string ?? "",
                       rightFavoriteID: row["right_favorite_id"]?.string, rightPath: row["right_path"]?.string ?? "",
                       options: o)
    }
}
