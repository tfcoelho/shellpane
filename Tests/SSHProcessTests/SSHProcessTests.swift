import Foundation
import SFTPKit
import Testing
@testable import SSHProcess

@Suite struct SSHTargetTests {
    @Test(arguments: [
        ("example.com", "example.com", nil, nil),
        ("deploy@example.com", "example.com", "deploy", nil),
        ("deploy@example.com:2222", "example.com", "deploy", 2222),
        ("example.com:2222", "example.com", nil, 2222),
        ("sftp://deploy@example.com:2200/var/www", "example.com", "deploy", 2200),
        ("[::1]:2222", "::1", nil, 2222),
        ("fe80::1", "fe80::1", nil, nil),
        ("  prod  ", "prod", nil, nil),
    ] as [(String, String, String?, Int?)])
    func parses(input: String, host: String, user: String?, port: Int?) throws {
        let t = try #require(SSHTarget(parsing: input))
        #expect(t.host == host)
        #expect(t.user == user)
        #expect(t.port == port)
    }

    @Test(arguments: ["", "-oProxyCommand=evil", "host name", "-l@host", "host:99999", "a\nb"])
    func rejectsUnsafe(input: String) {
        #expect(SSHTarget(parsing: input) == nil)
    }

    @Test func argumentsEndWithSubsystemAfterDoubleDash() {
        let args = SSHCommand.sftpArguments(for: SSHTarget(host: "h", port: 2222, user: "u", identityFile: "/k"))
        #expect(Array(args.suffix(4)) == ["-s", "--", "h", "sftp"])
        #expect(args.contains("-T"))
        #expect(args.contains("-a"))
        #expect(args.contains("-oIdentitiesOnly=yes"))
        let p = try! #require(args.firstIndex(of: "-p"))
        #expect(args[p + 1] == "2222")
    }
}

@Suite struct ShellCommandTests {
    @Test(arguments: ["/var/www", "/srv/my site", "/home/o'brien/it's", "/data/📁 Fotos Ñandú", "/tmp/$(rm -rf ~)", "/a`b`;c&&d|e"])
    func quotingSurvivesARealShell(path: String) throws {
        // Run the quoted string through /bin/sh and check it comes back unchanged.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + SSHCommand.shellQuote(path)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == path)
    }

    @Test func warpConfigurationQuotesEverything() {
        let cmd = SSHCommand.commandLine("/usr/bin/ssh", SSHCommand.shellArguments(for: SSHTarget(host: "web-1"), path: "/srv/it's"))
        let yaml = SSHCommand.warpLaunchConfiguration(name: "Shellpane", title: "web-1: it's", cwd: "/Users/me", command: cmd)
        #expect(yaml.contains("name: 'Shellpane'"))
        #expect(yaml.contains("title: 'web-1: it''s'"))
        // The exec line, un-YAML'd, is exactly the shell command line.
        let line = yaml.split(separator: "\n").first { $0.contains("- exec: ") }.map(String.init) ?? ""
        let value = String(line.split(separator: "- exec: ", maxSplits: 1)[1])
        #expect(value.hasPrefix("'") && value.hasSuffix("'"))
        #expect(String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") == cmd)
    }

    @Test func shellArgumentsCdThenLoginShell() {
        let args = SSHCommand.shellArguments(for: SSHTarget(host: "web-1", port: 2222, user: "deploy"), path: "/var/www")
        #expect(args.first == "-t")
        #expect(Array(args.suffix(3)) == ["--", "web-1", "cd '/var/www' && exec \"$SHELL\" -l"])
        #expect(args.contains("2222"))
    }
}

@Suite struct ShellEnvironmentTests {
    func fakeShell(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)").path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func readsTheAgentSocketDespiteNoisyStartupFiles() throws {
        // Behaves like a login shell whose rc files print things and export SSH_AUTH_SOCK.
        let shell = try fakeShell("""
        echo "Welcome back! (from .zshrc)"
        SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"; export SSH_AUTH_SOCK
        while [ "$1" != "-c" ]; do shift; done
        exec /bin/sh -c "$2"
        """)
        defer { try? FileManager.default.removeItem(atPath: shell) }
        let env = ShellEnvironment.read(["SSH_AUTH_SOCK", "NOT_SET_ANYWHERE"], shell: shell)
        #expect(env["SSH_AUTH_SOCK"]?.hasSuffix("2BUA8C4S2C.com.1password/t/agent.sock") == true)
        #expect(env["NOT_SET_ANYWHERE"] == nil)
    }

    @Test func aHangingShellIsAbandonedQuickly() throws {
        let shell = try fakeShell("sleep 30")
        defer { try? FileManager.default.removeItem(atPath: shell) }
        let start = Date()
        #expect(ShellEnvironment.read(["SSH_AUTH_SOCK"], shell: shell, timeout: 1).isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func theRealLoginShellAnswers() {
        // Whatever your shell is, it must come back (empty or not) within the timeout without hanging.
        let start = Date()
        _ = ShellEnvironment.read(["SSH_AUTH_SOCK"])
        #expect(Date().timeIntervalSince(start) < 7)
    }

    @Test func diagnosticCommandIsTheSameLoginVerbose() {
        let args = SSHCommand.diagnosticArguments(for: SSHTarget(host: "web-1", port: 2222, user: "deploy"))
        #expect(args.first == "-v")
        #expect(Array(args.suffix(3)) == ["--", "web-1", "exit"])
        #expect(args.contains("2222") && args.contains("deploy"))
    }
}

@Suite struct SSHConfigTests {
    @Test func collectsConcreteHostsAndFollowsIncludes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        # comment
        Include conf.d/*.conf
        Host prod staging
          HostName 10.0.0.1
        Host *.internal !bastion
        Host="quoted name"
        Host *
          ServerAliveInterval 30
        Include config
        """.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host web-1\nHost prod\n".write(to: dir.appendingPathComponent("conf.d/a.conf"), atomically: true, encoding: .utf8)
        try "host db\n".write(to: dir.appendingPathComponent("conf.d/b.conf"), atomically: true, encoding: .utf8)

        #expect(SSHConfig.hosts(in: dir.appendingPathComponent("config")) == ["web-1", "prod", "db", "staging", "quoted name"])
    }

    @Test func missingConfigIsEmpty() {
        #expect(SSHConfig.hosts(in: URL(fileURLWithPath: "/nonexistent/config")).isEmpty)
    }

    @Test func parsesSSHDashG() {
        let r = SSHConfig.parseResolved("""
        user deploy
        hostname 10.0.0.5
        port 2222
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_rsa
        proxyjump bastion
        """)
        #expect(r == .init(hostname: "10.0.0.5", user: "deploy", port: 2222,
                           identityFiles: ["~/.ssh/id_ed25519", "~/.ssh/id_rsa"], proxyJump: "bastion"))
    }
}

@Suite struct SSHFailureTests {
    @Test(arguments: [
        ("deploy@h: Permission denied (publickey,password).", SSHFailure.Kind.authFailed),
        ("ssh: Could not resolve hostname nope: nodename nor servname provided, or not known", .unknownHost),
        ("ssh: connect to host h port 22: Connection refused", .refused),
        ("ssh: connect to host h port 22: Operation timed out", .timeout),
        ("ssh: connect to host h port 22: No route to host", .unreachable),
        ("@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n...\nHost key verification failed.", .hostKeyChanged),
        ("Host key verification failed.", .hostKeyNotTrusted),
        ("subsystem request failed on channel 0", .sftpUnavailable),
        ("", .other),
    ] as [(String, SSHFailure.Kind)])
    func classifies(stderr: String, kind: SSHFailure.Kind) {
        let f = SSHFailure.from(status: 255, stderr: stderr, host: "h")
        #expect(f.kind == kind)
        #expect(!f.message.isEmpty)
    }

    @Test func classifiesAskpassPrompts() {
        #expect(AskpassRequest(prompt: "Enter passphrase for key '/k': ", hint: "").kind == .secret)
        let hk = AskpassRequest(prompt: "ED25519 key fingerprint is SHA256:abcDEF123+/x.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ", hint: "")
        #expect(hk.kind == .hostKey)
        #expect(hk.fingerprint == "SHA256:abcDEF123+/x")
        #expect(AskpassRequest(prompt: "Confirm user presence", hint: "none").kind == .notice)
    }
}

// MARK: - End to end: real ssh, real sshd, real askpass helper

/// A throwaway sshd on 127.0.0.1, running as the current user with its own host key,
/// a passphrase-protected client key and an empty known_hosts. Never touches ~/.ssh.
final class SSHDFixture: @unchecked Sendable {
    let dir: URL
    let port: Int
    let configFile: String
    let passphrase = "correct horse battery"
    private var sshd = Process()

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: Darwin.realpath(tmp.path, nil).map { String(cString: $0) } ?? tmp.path)
        port = Int.random(in: 40000...59000)
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("hostkey").path])
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-f", dir.appendingPathComponent("client").path])
        try FileManager.default.copyItem(at: dir.appendingPathComponent("client.pub"), to: dir.appendingPathComponent("authorized_keys"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("known_hosts").path, contents: nil)
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(dir.path)/hostkey
        PidFile \(dir.path)/sshd.pid
        AuthorizedKeysFile \(dir.path)/authorized_keys
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PerSourcePenalties no
        Subsystem sftp /usr/libexec/sftp-server
        """.write(to: dir.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
        configFile = dir.appendingPathComponent("ssh_config").path
        try """
        Host testbox
          HostName 127.0.0.1
          Port \(port)
          User \(NSUserName())
          IdentityFile \(dir.path)/client
          IdentitiesOnly yes
          IdentityAgent none
          UserKnownHostsFile \(dir.path)/known_hosts
          StrictHostKeyChecking ask
          ControlMaster no
          ControlPath none
        """.write(toFile: configFile, atomically: true, encoding: .utf8)

        try start()
    }

    private func start() throws {
        sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-e", "-f", dir.appendingPathComponent("sshd_config").path,
                          "-E", dir.appendingPathComponent("sshd.log").path]
        try sshd.run()
        for _ in 0..<50 {
            if Self.listening(port) { break }
            usleep(100_000)
        }
    }

    static func listening(_ port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-z", "127.0.0.1", String(port)]
        p.standardOutput = nil
        p.standardError = nil
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }

    func replaceHostKey() throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent("hostkey"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("hostkey.pub"))
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("hostkey").path])
        // sshd loads host keys once at startup: restart it on the same port.
        sshd.terminate()
        sshd.waitUntilExit()
        try start()
    }

    var log: String { (try? String(contentsOf: dir.appendingPathComponent("sshd.log"), encoding: .utf8)) ?? "" }

    deinit {
        if ProcessInfo.processInfo.environment["SHELLPANE_KEEP_SSHD"] != nil { print("sshd dir:", dir.path); sshd.terminate(); return }
        sshd.terminate()
        sshd.waitUntilExit()
        try? FileManager.default.removeItem(at: dir)
    }
}

final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AskpassRequest] = []
    func add(_ r: AskpassRequest) { lock.withLock { items.append(r) } }
    var all: [AskpassRequest] { lock.withLock { items } }
}

/// SwiftPM builds shellpane-askpass next to the test bundle.
func askpassHelper() throws -> URL {
    let bundle = Bundle(for: SSHDFixture.self).bundleURL
    let candidates = [bundle.deletingLastPathComponent(), bundle.deletingLastPathComponent().deletingLastPathComponent()]
    for dir in candidates {
        let url = dir.appendingPathComponent("shellpane-askpass")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "shellpane-askpass near \(bundle.path)"])
}

@Suite(.serialized) struct EndToEndTests {
    @Test func connectsThroughSSHWithHostKeyPromptAndPassphrase() async throws {
        let sshd = try SSHDFixture()
        let prompts = PromptLog()
        let server = try AskpassServer { request in
            prompts.add(request)
            switch request.kind {
            case .hostKey: return "yes"
            case .secret: return sshd.passphrase
            default: return nil
            }
        }
        defer { server.close() }
        try "hello".write(to: sshd.dir.appendingPathComponent("greeting.txt"), atomically: true, encoding: .utf8)

        let client = try await SSHConnection.open(SSHTarget(host: "testbox"), askpass: server,
                                                  helper: try askpassHelper(), token: "attempt-42",
                                                  configFile: sshd.configFile)
        defer { client.close() }

        let names = try await client.list(sshd.dir.path).map(\.name)
        #expect(names.contains("greeting.txt"))
        let dest = sshd.dir.appendingPathComponent("downloaded.txt")
        try await client.download(sshd.dir.appendingPathComponent("greeting.txt").path, to: dest)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "hello")

        let kinds = prompts.all.map(\.kind)
        #expect(kinds.first == .hostKey)
        #expect(prompts.all.first?.fingerprint?.hasPrefix("SHA256:") == true)
        #expect(kinds.contains(.secret))
        #expect(prompts.all.allSatisfy { !$0.prompt.contains(sshd.passphrase) })
        #expect(prompts.all.allSatisfy { $0.token == "attempt-42" })
    }

    @Test func wrongPassphraseIsAnAuthFailure() async throws {
        let sshd = try SSHDFixture()
        let server = try AskpassServer { request in
            request.kind == .hostKey ? "yes" : "wrong"
        }
        defer { server.close() }
        do {
            let client = try await SSHConnection.open(SSHTarget(host: "testbox"), askpass: server,
                                                      helper: try askpassHelper(), configFile: sshd.configFile)
            client.close()
            Issue.record("expected the login to fail")
        } catch let e as SSHConnectError {
            #expect(e.localizedDescription.contains("didn't accept the login"))
            #expect(e.failure.raw.lowercased().contains("permission denied"))   // what ssh really said, for Details
            #expect(e.testCommand.hasPrefix("'/usr/bin/ssh' '-v'"))
        }
    }

    @Test func refusingTheHostKeyStopsTheConnection() async throws {
        let sshd = try SSHDFixture()
        let server = try AskpassServer { request in
            request.kind == .hostKey ? "no" : sshd.passphrase
        }
        defer { server.close() }
        await #expect(throws: SSHConnectError.self) {
            _ = try await SSHConnection.open(SSHTarget(host: "testbox"), askpass: server,
                                             helper: try askpassHelper(), configFile: sshd.configFile)
        }
    }

    @Test func changedHostKeyIsBlockedWithoutAPrompt() async throws {
        let sshd = try SSHDFixture()
        let prompts = PromptLog()
        let server = try AskpassServer { request in
            prompts.add(request)
            return request.kind == .hostKey ? "yes" : sshd.passphrase
        }
        defer { server.close() }
        let helper = try askpassHelper()
        let first = try await SSHConnection.open(SSHTarget(host: "testbox"), askpass: server, helper: helper, configFile: sshd.configFile)
        first.close()

        try sshd.replaceHostKey()
        let before = prompts.all.count
        do {
            let second = try await SSHConnection.open(SSHTarget(host: "testbox"), askpass: server, helper: helper, configFile: sshd.configFile)
            second.close()
            Issue.record("expected the changed host key to be refused")
        } catch let e as SSHConnectError {
            #expect(e.localizedDescription.contains("identity has changed"))
            #expect(e.failure.kind == .hostKeyChanged)
        }
        #expect(!prompts.all.dropFirst(before).contains { $0.kind == .hostKey })
    }

    /// F08: the exact command Open in Terminal runs, through real ssh and the server's shell, lands in the folder.
    @Test func openInTerminalCommandLandsInTheFolder() async throws {
        let sshd = try SSHDFixture()
        let tricky = sshd.dir.appendingPathComponent("📁 it's a \"site\" $HOME").path
        try FileManager.default.createDirectory(atPath: tricky, withIntermediateDirectories: true)
        // The fixture's client key has a passphrase; give ssh a plain copy for this non-interactive check.
        let plainKey = sshd.dir.appendingPathComponent("plain").path
        try SSHDFixture.run("/bin/cp", [sshd.dir.appendingPathComponent("client").path, plainKey])
        try SSHDFixture.run("/usr/bin/ssh-keygen", ["-q", "-p", "-P", sshd.passphrase, "-N", "", "-f", plainKey])
        let known = sshd.dir.appendingPathComponent("known_hosts").path
        let p = Process()
        p.executableURL = SSHCommand.executable
        p.arguments = ["-oStrictHostKeyChecking=accept-new", "-oUserKnownHostsFile=" + known, "-oBatchMode=yes"]
            + SSHCommand.shellArguments(for: SSHTarget(host: "127.0.0.1", port: sshd.port, user: NSUserName(), identityFile: plainKey),
                                        path: tricky, configFile: "/dev/null", interactive: false, then: "pwd")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        #expect(p.terminationStatus == 0)
        #expect(printed == tricky)
    }

    @Test func nothingListeningIsRefused() async throws {
        let server = try AskpassServer { _ in nil }
        defer { server.close() }
        let cfg = FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-empty-\(UUID().uuidString)").path
        try "".write(toFile: cfg, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: cfg) }
        do {
            _ = try await SSHConnection.open(SSHTarget(host: "127.0.0.1", port: 1), askpass: server,
                                             helper: try askpassHelper(), configFile: cfg)
            Issue.record("expected a refusal")
        } catch let e as SSHConnectError {
            #expect(e.localizedDescription.contains("refused"))
            #expect(e.failure.raw.contains("Connection refused"))
        }
    }
}
