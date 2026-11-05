import Foundation

/// An icon (an SF Symbol name) and a colour chosen for something in the sidebar. nil keeps its default.
public struct Appearance: Equatable, Sendable {
    public var icon: String?
    public var colour: String?

    public init(icon: String? = nil, colour: String? = nil) {
        self.icon = icon
        self.colour = colour
    }

    public var isDefault: Bool { icon == nil && colour == nil }
}

/// What an appearance belongs to. Saved servers and favorite folders keep theirs in their own rows.
public enum AppearanceKey {
    public static func host(_ alias: String) -> String { "host:" + alias }
    public static func place(_ path: String) -> String { "place:" + path }
    public static func synclet(_ id: String) -> String { "synclet:" + id }
    public static func group(_ id: String) -> String { "group:" + id }
    public static func tag(_ name: String) -> String { "tag:" + name }
}

public final class AppearancesStore: @unchecked Sendable {
    private let db: Database

    public init(database: Database) { self.db = database }

    public func all() throws -> [String: Appearance] {
        var result: [String: Appearance] = [:]
        for row in try db.query("SELECT * FROM appearances") {
            guard let key = row["key"]?.string else { continue }
            result[key] = Appearance(icon: row["icon"]?.string, colour: row["colour"]?.string)
        }
        return result
    }

    /// Saves it; back to the default, there's nothing to keep.
    public func set(_ key: String, _ appearance: Appearance) throws {
        if appearance.isDefault { return try remove(key) }
        try db.execute("""
            INSERT INTO appearances (key, icon, colour) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET icon = excluded.icon, colour = excluded.colour, updated_at = unixepoch()
            """, [.text(key), appearance.icon.sql, appearance.colour.sql])
    }

    public func remove(_ key: String) throws {
        try db.execute("DELETE FROM appearances WHERE key = ?", [.text(key)])
    }
}
