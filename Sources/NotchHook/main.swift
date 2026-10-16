// notch-hook / notch: talks to Notch Island over its local socket.
//
// With no arguments it's the Claude Code hook: it forwards the hook's JSON from stdin and, for
// PermissionRequest, waits for Yes/Always/No and prints Claude Code's decision JSON. If the app isn't
// running or nobody answers in time, it prints nothing and exits 0, so Claude Code carries on as usual.
//
// With arguments it's the `notch` command for any script (see `notch help`).
import Foundation

let env = ProcessInfo.processInfo.environment
let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NotchIsland/notch.sock").path

/// Connects to the app; nil if it isn't running.
func connectToApp() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        socketPath.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    } == 0
    if !ok { close(fd); return nil }
    return fd
}

/// Sends one JSON line, tagged with the app this runs in (iTerm2, Terminal, IntelliJ…).
@discardableResult
func send(_ fd: Int32, _ obj: [String: Any]) -> Bool {
    var o = obj
    o["notch_app_bundle"] = env["__CFBundleIdentifier"]
    o["notch_term_program"] = env["TERM_PROGRAM"]
    guard var data = try? JSONSerialization.data(withJSONObject: o) else { return false }
    data.append(UInt8(ascii: "\n"))
    return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
}

/// Waits up to `seconds` for one reply line.
func readReply(_ fd: Int32, seconds: Double) -> String? {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&pfd, 1, Int32(seconds * 1000)) > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buf, buf.count)
    guard n > 0 else { return nil }
    return String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines)
}

// MARK: - `notch` command

func cli(_ args: [String]) -> Int32 {
    let usage = """
    notch "message"                     show a bubble in the notch
    notch done ["message"]              ✓ bubble          notch fail ["message"]   ✗ bubble
    notch progress <0-100|done> [title] live progress in the notch pill
    notch run [--title T] -- cmd args…  run a command; shows it working, then Done/Failed with the time
    notch ask "question" [detail]       Yes/No in the island; exit 0 = yes, 1 = no, 2 = no answer
    """
    guard let first = args.first, !["help", "-h", "--help"].contains(first) else { print(usage); return 0 }
    let rest = Array(args.dropFirst())

    switch first {
    case "run":
        guard let dash = rest.firstIndex(of: "--"), dash + 1 < rest.count else { print(usage); return 64 }
        let command = Array(rest[(dash + 1)...])
        let title = rest.firstIndex(of: "--title").flatMap { $0 + 1 < dash ? rest[$0 + 1] : nil } ?? command.joined(separator: " ")
        let fd = connectToApp()
        if let fd { send(fd, ["hook_event_name": "NotchCLI", "action": "task-start", "title": title]) }
        // The connection stays open while the command runs: if this is interrupted, the app notices.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = command
        let started = Date()
        do { try p.run() } catch { fputs("notch: \(error.localizedDescription)\n", stderr); if let fd { close(fd) }; return 127 }
        signal(SIGINT, SIG_IGN) // Ctrl-C goes to the command; we report how it ended
        p.waitUntilExit()
        let code = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
        if let fd {
            send(fd, ["hook_event_name": "NotchCLI", "action": "task-end", "title": title,
                      "code": Int(code), "seconds": Date().timeIntervalSince(started)])
            close(fd)
        }
        return code
    case "ask":
        guard let question = rest.first, let fd = connectToApp() else { return 2 }
        send(fd, ["hook_event_name": "NotchCLI", "action": "ask", "title": question, "detail": rest.dropFirst().joined(separator: " ")])
        let reply = readReply(fd, seconds: Double(env["NOTCH_ASK_WAIT"] ?? "") ?? 300)
        close(fd)
        return reply == "allow" ? 0 : reply?.hasPrefix("deny") == true ? 1 : 2
    case "progress":
        guard let value = rest.first, let fd = connectToApp() else { return 0 }
        send(fd, ["hook_event_name": "NotchCLI", "action": "progress", "value": value,
                  "title": rest.dropFirst().joined(separator: " ")])
        close(fd)
    case "done", "fail":
        guard let fd = connectToApp() else { return 0 }
        send(fd, ["hook_event_name": "NotchCLI", "action": first, "title": rest.joined(separator: " ")])
        close(fd)
    default:
        guard let fd = connectToApp() else { return 0 }
        send(fd, ["hook_event_name": "NotchCLI", "action": "say", "title": args.joined(separator: " ")])
        close(fd)
    }
    return 0
}

if CommandLine.arguments.count > 1 { exit(cli(Array(CommandLine.arguments.dropFirst()))) }

// MARK: - Claude Code hook (stdin JSON)

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
let event = obj["hook_event_name"] as? String ?? ""
let wait = Double(env["NOTCH_HOOK_WAIT"] ?? "") ?? 120

guard let fd = connectToApp() else { exit(0) } // app not running
guard send(fd, obj), event == "PermissionRequest" else { close(fd); exit(0) }

// Wait for "allow", "always" or "deny\t<reason>".
guard let reply = readReply(fd, seconds: wait) else { close(fd); exit(0) }
close(fd)
let parts = reply.split(separator: "\t", maxSplits: 1).map(String.init)

var decision: [String: Any]
switch parts.first {
case "allow": decision = ["behavior": "allow"]
case "always":
    // "Yes, and don't ask again": hand back Claude Code's own suggested rule, as the terminal does.
    decision = ["behavior": "allow"]
    if let s = obj["permission_suggestions"] as? [Any], !s.isEmpty { decision["updatedPermissions"] = s }
case "deny": decision = ["behavior": "deny", "message": parts.count > 1 ? parts[1] : "Denied from Notch Island"]
default: exit(0)
}
let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
if let data = try? JSONSerialization.data(withJSONObject: out) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
