import Foundation
import SFTPKit

/// Where to connect. Either a Host alias from ~/.ssh/config (ssh resolves everything else),
/// or a host with optional overrides. Overrides win over ssh_config, as on the command line.
public struct SSHTarget: Sendable, Equatable, Codable {
    public var host: String
    public var port: Int?
    public var user: String?
    /// IdentityFile override. nil = whatever ssh_config and the agent offer.
    public var identityFile: String?

    public init(host: String, port: Int? = nil, user: String? = nil, identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
    }

    /// Parses what people type: "host", "user@host", "user@host:2222", "host:2222",
    /// "[::1]:2222", "sftp://user@host:2222/path". Returns nil for anything unsafe to hand to ssh.
    public init?(parsing input: String) {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("sftp://") || s.lowercased().hasPrefix("ssh://") {
            s = String(s[s.range(of: "://")!.upperBound...])
            if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        }
        var user: String?
        if let at = s.lastIndex(of: "@") {
            user = String(s[..<at]).removingPercentEncoding
            s = String(s[s.index(after: at)...])
        }
        var port: Int?
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {  // [ipv6]:port
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
            s = String(s[s.index(after: s.startIndex)..<close])
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            port = Int(s[s.index(after: colon)...])
            s = String(s[..<colon])
        }
        guard Self.isSafe(host: s), user.map(Self.isSafe(user:)) ?? true else { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        self.init(host: s, port: port, user: (user?.isEmpty ?? true) ? nil : user)
    }

    /// No option injection ("-oProxyCommand=…"), no whitespace or control characters.
    public static func isSafe(host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.count <= 255
            && host.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    public static func isSafe(user: String) -> Bool {
        !user.hasPrefix("-") && user.count <= 255
            && user.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    public var displayName: String {
        user.map { "\($0)@\(host)" } ?? host
    }
}

public enum SSHCommand {
    public static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    /// Arguments for `ssh … -s -- host sftp`.
    /// - configFile: `-F` path (tests use a throwaway config; the app passes nil for ~/.ssh/config).
    public static func sftpArguments(for target: SSHTarget, configFile: String? = nil, extraOptions: [String] = []) -> [String] {
        var args = [
            "-T",                              // no TTY: prompts go through askpass
            "-x", "-a",                        // no X11, no agent forwarding to the server
            "-oClearAllForwardings=yes",       // a file browser never needs the user's port forwards
            "-oPermitLocalCommand=no",
            "-oServerAliveInterval=15",
            "-oServerAliveCountMax=3",
            "-oConnectTimeout=20",
        ]
        if let configFile { args += ["-F", configFile] }
        if let port = target.port { args += ["-p", String(port)] }
        if let user = target.user { args += ["-l", user] }
        if let key = target.identityFile { args += ["-i", key, "-oIdentitiesOnly=yes"] }
        args += extraOptions
        args += ["-s", "--", target.host, "sftp"]
        return args
    }

    /// "Try it in Terminal": the same login as Shellpane's, verbose, running `exit` instead of the file session.
    public static func diagnosticArguments(for target: SSHTarget, configFile: String? = nil, extraOptions: [String] = []) -> [String] {
        var args = ["-v", "-oConnectTimeout=20"]
        if let configFile { args += ["-F", configFile] }
        if let port = target.port { args += ["-p", String(port)] }
        if let user = target.user { args += ["-l", user] }
        if let key = target.identityFile { args += ["-i", key, "-oIdentitiesOnly=yes"] }
        args += extraOptions
        args += ["--", target.host, "exit"]
        return args
    }

    /// F08: arguments for an interactive shell on the server, starting in `path`.
    /// `then` replaces the login shell (tests use "pwd" to check the quoting through a real shell).
    public static func shellArguments(for target: SSHTarget, path: String, configFile: String? = nil,
                                      interactive: Bool = true, then: String = "exec \"$SHELL\" -l") -> [String] {
        var args = [interactive ? "-t" : "-T"]
        if let configFile { args += ["-F", configFile] }
        if let port = target.port { args += ["-p", String(port)] }
        if let user = target.user { args += ["-l", user] }
        if let key = target.identityFile { args += ["-i", key, "-oIdentitiesOnly=yes"] }
        args += ["--", target.host, "cd " + shellQuote(path) + " && " + then]
        return args
    }

    /// Single-quotes a string for a POSIX shell: it's then taken literally, whatever it contains.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// YAML single-quoted scalar: only `'` needs escaping (as `''`); everything else is literal.
    public static func yamlQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A Warp launch configuration that opens one tab running `command` (Warp doesn't run .command files).
    public static func warpLaunchConfiguration(name: String, title: String, cwd: String, command: String) -> String {
        """
        ---
        name: \(yamlQuote(name))
        windows:
          - tabs:
              - title: \(yamlQuote(title))
                layout:
                  cwd: \(yamlQuote(cwd))
                  commands:
                    - exec: \(yamlQuote(command))

        """
    }

    /// A whole command line, each word quoted, for a .command file.
    public static func commandLine(_ executable: String, _ args: [String]) -> String {
        ([executable] + args).map(shellQuote).joined(separator: " ")
    }
}
