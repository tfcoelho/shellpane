import Foundation

/// Reads Host aliases out of ~/.ssh/config (following Include), and asks ssh itself what an alias resolves to.
/// We never interpret the rest of the config: ssh does that when it connects.
public enum SSHConfig {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// Concrete Host aliases, in file order, without wildcard or negated patterns.
    public static func hosts(in url: URL = defaultURL) -> [String] {
        var seen = Set<String>()
        var visited = Set<String>()
        var result: [String] = []
        collect(url, sshDir: url.deletingLastPathComponent(), seen: &seen, visited: &visited, into: &result, depth: 0)
        return result
    }

    private static func collect(_ url: URL, sshDir: URL, seen: inout Set<String>, visited: inout Set<String>,
                                into result: inout [String], depth: Int) {
        let key = url.standardizedFileURL.path
        guard depth < 16, !visited.contains(key), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        visited.insert(key)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (keyword, args) = parse(line: String(line)) else { continue }
            switch keyword {
            case "host":
                for pattern in args where !pattern.contains(where: { "*?!".contains($0) }) && !seen.contains(pattern) {
                    seen.insert(pattern)
                    result.append(pattern)
                }
            case "include":
                for arg in args {
                    for file in expandInclude(arg, sshDir: sshDir) {
                        collect(file, sshDir: sshDir, seen: &seen, visited: &visited, into: &result, depth: depth + 1)
                    }
                }
            default:
                continue
            }
        }
    }

    /// "Keyword arg1 arg2", "Keyword=arg", quoted args. Returns a lowercased keyword.
    static func parse(line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for ch in trimmed {
            if ch == "\"" { quoted.toggle(); hasToken = true; continue }
            if !quoted && (ch == " " || ch == "\t" || (ch == "=" && tokens.isEmpty)) {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        guard let first = tokens.first else { return nil }
        return (first.lowercased(), Array(tokens.dropFirst()))
    }

    static func expandInclude(_ pattern: String, sshDir: URL) -> [URL] {
        var path = pattern
        if path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        } else if !path.hasPrefix("/") {
            path = sshDir.appendingPathComponent(path).path
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(path, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { i in
            g.gl_pathv[i].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    /// What ssh will actually use for an alias: `ssh -G alias`.
    public struct Resolved: Sendable, Equatable {
        public var hostname: String
        public var user: String
        public var port: Int
        public var identityFiles: [String]
        public var proxyJump: String?
    }

    public static func resolve(_ alias: String, configFile: String? = nil) throws -> Resolved {
        guard SSHTarget.isSafe(host: alias) else { throw CocoaError(.fileReadInvalidFileName) }
        let p = Process()
        p.executableURL = SSHCommand.executable
        p.arguments = (configFile.map { ["-F", $0] } ?? []) + ["-G", "--", alias]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseResolved(String(decoding: data, as: UTF8.self))
    }

    static func parseResolved(_ text: String) -> Resolved {
        var r = Resolved(hostname: "", user: "", port: 22, identityFiles: [], proxyJump: nil)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname": r.hostname = parts[1]
            case "user": r.user = parts[1]
            case "port": r.port = Int(parts[1]) ?? 22
            case "identityfile": r.identityFiles.append(parts[1])
            case "proxyjump": r.proxyJump = parts[1] == "none" ? nil : parts[1]
            default: break
            }
        }
        return r
    }
}
