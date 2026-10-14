// notch-hook: called by Claude Code hooks. Forwards the hook's JSON to Notch Island over a local socket.
// For PermissionRequest it waits for Allow/Deny and prints Claude Code's decision JSON.
// If the app isn't running, or nobody answers in time, it prints nothing and exits 0,
// so Claude Code carries on exactly as it would without the hook.
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
// Which app runs this Claude Code session (iTerm2, Terminal, IntelliJ, VS Code…), so the island can name it.
let env = ProcessInfo.processInfo.environment
obj["notch_app_bundle"] = env["__CFBundleIdentifier"]
obj["notch_term_program"] = env["TERM_PROGRAM"]
let event = obj["hook_event_name"] as? String ?? ""
let wait = Double(ProcessInfo.processInfo.environment["NOTCH_HOOK_WAIT"] ?? "") ?? 120

let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NotchIsland/notch.sock").path
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
} == 0
guard connected else { exit(0) } // app not running

var msg = (try? JSONSerialization.data(withJSONObject: obj)) ?? input
msg.append(UInt8(ascii: "\n"))
let sent = msg.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
guard sent == msg.count, event == "PermissionRequest" else { close(fd); exit(0) }

// Wait for "allow", "always" or "deny\t<reason>".
var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
guard poll(&pfd, 1, Int32(wait * 1000)) > 0 else { close(fd); exit(0) }
var buf = [UInt8](repeating: 0, count: 4096)
let n = read(fd, &buf, buf.count)
close(fd)
guard n > 0 else { exit(0) }
let reply = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines)
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
exit(0)
