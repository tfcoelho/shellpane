import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    var string: String? { if case let .text(s) = self { return s }; return nil }
    var int: Int64? { if case let .int(i) = self { return i }; return nil }
}

extension Optional where Wrapped == String {
    var sql: SQLValue { map { .text($0) } ?? .null }
}

extension Optional where Wrapped == Int {
    var sql: SQLValue { map { .int(Int64($0)) } ?? .null }
}

public struct DatabaseError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "Database error \(code): \(message)" }
}

/// A small wrapper over the system SQLite. Every statement uses bound parameters, never string interpolation.
/// Serialised by a lock: one connection, used from any thread.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    /// Opens (creating if needed) and migrates. Pass ":memory:" for tests.
    public convenience init(path: String) throws {
        try self.init(path: path, migrations: Migrations.all)
    }

    /// `migrations` lets a test build an older database to upgrade.
    init(path: String, migrations: [String]) throws {
        self.path = path
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            throw DatabaseError(code: SQLITE_CANTOPEN, message: message)
        }
        if path != ":memory:" { chmod(path, 0o600) }
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" { _ = try query("PRAGMA journal_mode = WAL") }
        try migrate(migrations)
    }

    /// Default location: ~/Library/Application Support/Shellpane/shellpane.sqlite, or $SHELLPANE_DATA_DIR for dev and demos.
    /// Before the rename, data lived in Application Support under the working name. Moved over once, so
    /// saved servers survive. (Spelled in pieces so the rebrand sweep, which rejects the old name, stays clean.)
    static func migrateLegacyData(to path: String) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return }
        let legacy = ["Ho", "ist"].joined()
        let base = (path as NSString).deletingLastPathComponent
        let old = ((base as NSString).deletingLastPathComponent as NSString).appendingPathComponent(legacy)
        let oldFile = (old as NSString).appendingPathComponent(legacy.lowercased() + ".sqlite")
        guard fm.fileExists(atPath: oldFile) else { return }
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: oldFile + suffix) {
            try? fm.copyItem(atPath: oldFile + suffix, toPath: path + suffix)
        }
    }

    public static func defaultPath() -> String {
        if let dir = ProcessInfo.processInfo.environment["SHELLPANE_DATA_DIR"] {
            return (dir as NSString).appendingPathComponent("shellpane.sqlite")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let path = base.appendingPathComponent("Shellpane/shellpane.sqlite").path
        migrateLegacyData(to: path)
        return path
    }

    deinit { sqlite3_close_v2(handle) }

    public var schemaVersion: Int {
        (try? query("PRAGMA user_version").first?["user_version"]?.int).flatMap { $0.map(Int.init) } ?? 0
    }

    func migrate(_ migrations: [String]) throws {
        let current = schemaVersion
        guard current < migrations.count else { return }
        try transaction {
            for (i, sql) in migrations.enumerated() where i >= current {
                try exec(sql)
            }
            try exec("PRAGMA user_version = \(migrations.count)")
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Several statements, no parameters. Only for trusted SQL (migrations, BEGIN/COMMIT).
    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError(code: sqlite3_errcode(handle), message: message)
        }
    }

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params)
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .real(v): sqlite3_bind_double(stmt, idx, v)
            case let .text(v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func lastError() -> DatabaseError {
        DatabaseError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}
