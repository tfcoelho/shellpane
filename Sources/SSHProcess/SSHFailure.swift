import Foundation

/// Turns ssh's exit status and stderr into something a person can act on.
/// The raw text stays available behind "Details".
public struct SSHFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case authFailed, unknownHost, refused, timeout, unreachable
        case hostKeyChanged, hostKeyNotTrusted, sftpUnavailable, proxyFailed, other
    }

    public var kind: Kind
    public var message: String
    public var raw: String

    public static func from(status: Int32, stderr: String, host: String) -> SSHFailure {
        let raw = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        func make(_ kind: Kind, _ message: String) -> SSHFailure { SSHFailure(kind: kind, message: message, raw: raw) }

        // Order matters: a changed host key also prints "Host key verification failed".
        if lower.contains("remote host identification has changed") {
            return make(.hostKeyChanged, "\(host)'s identity has changed since you last connected. Someone may be intercepting the connection, or the server was reinstalled. Shellpane won't connect until you check.")
        }
        if lower.contains("host key verification failed") {
            return make(.hostKeyNotTrusted, "The connection was stopped because \(host)'s identity wasn't confirmed.")
        }
        if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
            return make(.unknownHost, "Couldn't find a server called “\(host)”. Check the address.")
        }
        if lower.contains("connection refused") {
            return make(.refused, "\(host) refused the connection. Check the port, and that SSH is running on the server.")
        }
        if lower.contains("timed out") {
            return make(.timeout, "\(host) didn't answer. It may be offline or behind a firewall.")
        }
        if lower.contains("no route to host") || lower.contains("network is unreachable") {
            return make(.unreachable, "There's no network route to \(host). Check your connection or VPN.")
        }
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            return make(.authFailed, "\(host) didn't accept the login. Check the username, password or key.")
        }
        if lower.contains("subsystem request failed") {
            return make(.sftpUnavailable, "\(host) accepts SSH logins but file transfer (SFTP) is turned off on the server.")
        }
        if lower.contains("proxyjump") || lower.contains("proxycommand") || lower.contains("jump host") {
            return make(.proxyFailed, "Couldn't reach \(host) through the jump host in your SSH config.")
        }
        if raw.isEmpty {
            return make(.other, "The connection to \(host) closed unexpectedly (ssh exit code \(status)).")
        }
        let lastLine = raw.split(whereSeparator: \.isNewline).last.map(String.init) ?? raw
        return make(.other, lastLine)
    }
}
