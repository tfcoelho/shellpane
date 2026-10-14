// shellpane-askpass: ssh runs this (SSH_ASKPASS) when it needs a password, a passphrase or a yes/no.
// It forwards the prompt to Shellpane over the Unix socket in SHELLPANE_ASKPASS_SOCKET and prints the answer.
// Exit 0 = answered, 1 = cancelled. Never logs or stores what it relays.

import Darwin
import Foundation

struct Request: Encodable { let prompt: String; let hint: String; let token: String? }
struct Reply: Decodable { let answer: String? }

let env = ProcessInfo.processInfo.environment
guard let socketPath = env["SHELLPANE_ASKPASS_SOCKET"] else {
    FileHandle.standardError.write(Data("shellpane-askpass: not started by Shellpane\n".utf8))
    exit(1)
}
let prompt = CommandLine.arguments.dropFirst().first ?? ""
let hint = env["SSH_ASKPASS_PROMPT"] ?? ""

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(1) }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    buf.copyBytes(from: pathBytes)
    buf[pathBytes.count] = 0
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(1) }

var out = (try? JSONEncoder().encode(Request(prompt: prompt, hint: hint, token: env["SHELLPANE_ASKPASS_TOKEN"]))) ?? Data()
out.append(0x0A)
_ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

var response = Data()
var byte: UInt8 = 0
while read(fd, &byte, 1) == 1, byte != 0x0A { response.append(byte) }
close(fd)

guard let reply = try? JSONDecoder().decode(Reply.self, from: response), let answer = reply.answer else { exit(1) }
if hint != "confirm" && hint != "none" {
    FileHandle.standardOutput.write(Data((answer + "\n").utf8))
}
exit(0)
