import Foundation
import SFTPKit

/// Opens an SFTP session through the system's OpenSSH.
public enum SSHConnection {
    /// The askpass helper ships next to the app's executable (Contents/MacOS/shellpane-askpass),
    /// and SwiftPM builds it next to the other products.
    public static func bundledAskpassHelper(near executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let dir = executable?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent("shellpane-askpass")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// - token: tags this attempt's askpass prompts (see AskpassRequest.token).
    /// - environment: variables to add for ssh (e.g. SSH_AUTH_SOCK from the login shell).
    /// Throws `SSHConnectError` with ssh's raw output and a command to test the same login by hand.
    public static func open(_ target: SSHTarget, askpass: AskpassServer, helper: URL, token: String? = nil,
                            configFile: String? = nil, extraOptions: [String] = [],
                            environment extra: [String: String] = [:]) async throws -> SFTPClient {
        let host = target.host
        var env = askpass.environment(helper: helper, token: token)
        for (k, v) in extra { env[k] = v }   // the caller's values win (e.g. the login shell's agent over launchd's)
        let transport = ProcessTransport(
            executable: SSHCommand.executable,
            arguments: SSHCommand.sftpArguments(for: target, configFile: configFile, extraOptions: extraOptions),
            environment: env,
            describeExit: { status, stderr in SSHFailure.from(status: status, stderr: stderr, host: host).message })
        let client = SFTPClient(transport: transport)
        do {
            try await client.connect()
        } catch {
            transport.close()
            let failure = SSHFailure.from(status: 255, stderr: transport.stderrText, host: host)
            throw SSHConnectError(failure: failure,
                                  testCommand: SSHCommand.commandLine("/usr/bin/ssh", SSHCommand.diagnosticArguments(for: target, configFile: configFile, extraOptions: extraOptions)))
        }
        return client
    }

    /// The failure behind a closed connection, with the raw ssh output for "Details".
    public static func failure(for client: SFTPClient, host: String) -> SSHFailure {
        SSHFailure.from(status: 255, stderr: client.transport.stderrText, host: host)
    }
}

/// A connection that never got going: what to tell the person, what ssh actually said, and a command
/// that tries the same login in Terminal with ssh's verbose output.
public struct SSHConnectError: Error, LocalizedError, Sendable {
    public let failure: SSHFailure
    public let testCommand: String
    public var errorDescription: String? { failure.message }
}
