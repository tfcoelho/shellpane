import Foundation

/// S09: what Shellpane did and how it went. Never holds secrets; messages are the same text people see.
public struct LogEntry: Identifiable, Equatable, Sendable {
    public enum Operation: String, Sendable, CaseIterable {
        case connect, disconnect, upload, download, copy, move, rename, mkdir, delete, chmod, sync
        case editUpload = "edit_upload"
    }

    public enum Result: String, Sendable { case ok, skipped, failed }

    public let id: Int64
    public let at: Date
    public let operation: Operation
    public let path: String?
    public let result: Result
    public let message: String?
    public let favoriteID: String?
}

public final class OperationLog: @unchecked Sendable {
    private let db: Database
    /// Called after each record, e.g. to refresh a visible log.
    public var onRecord: (@Sendable () -> Void)?

    public init(database: Database) { self.db = database }

    public func record(_ op: LogEntry.Operation, path: String?, result: LogEntry.Result = .ok,
                       message: String? = nil, favoriteID: String? = nil, at: Date = Date()) {
        try? db.execute("""
            INSERT INTO log_entries (at, operation, path, result, message, favorite_id)
            VALUES (?, ?, ?, ?, ?, (SELECT id FROM favorites WHERE id = ?))
            """, [.int(Int64(at.timeIntervalSince1970)), .text(op.rawValue), path.sql, .text(result.rawValue), message.sql, favoriteID.sql])
        onRecord?()
    }

    /// Newest first.
    public func recent(limit: Int = 500) throws -> [LogEntry] {
        try db.query("SELECT * FROM log_entries ORDER BY at DESC, id DESC LIMIT ?", [.int(Int64(limit))]).map { row in
            LogEntry(id: row["id"]?.int ?? 0,
                     at: Date(timeIntervalSince1970: TimeInterval(row["at"]?.int ?? 0)),
                     operation: LogEntry.Operation(rawValue: row["operation"]?.string ?? "") ?? .copy,
                     path: row["path"]?.string,
                     result: LogEntry.Result(rawValue: row["result"]?.string ?? "") ?? .ok,
                     message: row["message"]?.string,
                     favoriteID: row["favorite_id"]?.string)
        }
    }

    /// Launch-time housekeeping: drop entries older than `days`.
    public func prune(olderThanDays days: Int = 30, now: Date = Date()) {
        try? db.execute("DELETE FROM log_entries WHERE at < ?", [.int(Int64(now.timeIntervalSince1970) - Int64(days) * 86_400)])
    }

    public func clear() {
        try? db.execute("DELETE FROM log_entries")
    }
}
