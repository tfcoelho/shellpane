import Foundation

/// Apps opened from Finder don't get the variables your shell profile sets. An ssh agent configured with
/// `export SSH_AUTH_SOCK=…` in ~/.zshrc (1Password, Secretive) is invisible to them, so ssh can't find the
/// agent, while Terminal can. Shellpane reads them from your login shell once at launch.
public enum ShellEnvironment {
    static let begin = "__SHELLPANE_ENV_BEGIN__"
    static let end = "__SHELLPANE_ENV_END__"

    /// Runs `shell -i -l -c` (like a new Terminal tab), prints the environment between markers so noise
    /// from startup files is ignored, and returns the requested names that are set. Gives up after `timeout`.
    public static func read(_ names: [String], shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                            timeout: TimeInterval = 5) -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-i", "-l", "-c", "printf '\\n\(begin)\\n'; /usr/bin/env -0; printf '\(end)'"]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let collected = DataBox()
        let reader = Thread {
            collected.data = out.fileHandleForReading.readDataToEndOfFile()
            collected.done.signal()
        }
        reader.start()
        if collected.done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return [:]
        }
        p.waitUntilExit()
        return parse(collected.data, names: names)
    }

    static func parse(_ data: Data, names: [String]) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        guard let b = text.range(of: begin + "\n"), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else { return [:] }
        var result: [String: String] = [:]
        for pair in text[b.upperBound..<e.lowerBound].split(separator: "\0") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<eq])
            if names.contains(name) { result[name] = String(pair[pair.index(after: eq)...]) }
        }
        return result
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
        let done = DispatchSemaphore(value: 0)
    }
}
