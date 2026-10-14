import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Receives Claude Code hook events from `notch-hook` over a Unix socket that only you can open.
/// Socket: ~/Library/Application Support/NotchIsland/notch.sock (mode 0600)
@MainActor
final class ClaudeBridge: ObservableObject {
    static let shared = ClaudeBridge()

    enum Step: Equatable {
        case thinking, reading, editing, running, searching, other(String)
        var symbol: String {
            switch self {
            case .thinking: "sparkle"
            case .reading: "doc.text.magnifyingglass"
            case .editing: "pencil"
            case .running: "terminal"
            case .searching: "magnifyingglass"
            case .other: "gearshape"
            }
        }
        var verb: String {
            switch self {
            case .thinking: "Thinking"
            case .reading: "Reading"
            case .editing: "Editing"
            case .running: "Running"
            case .searching: "Searching"
            case .other(let tool): "Using \(tool)"
            }
        }
    }

    /// Same three choices as the terminal prompt.
    enum Answer { case yes, always, no }

    struct PermissionRequest: Identifiable {
        let id = UUID()
        let fd: Int32
        let tool: String
        let headline: String
        let body: String      // the whole command / input, never shortened
        let note: String?
        let project: String
        /// What "Always" saves, from Claude Code's own suggestion; nil when it offers none.
        let always: String?
        /// The terminal or IDE running that Claude Code session.
        let app: SourceApp?
    }

    /// The app a Claude Code session runs in (any terminal or IDE), from the hook's environment.
    struct SourceApp: Equatable {
        let bundleID: String
        let name: String

        init?(bundleID: String?, termProgram: String?) {
            let known = ["Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
                         "vscode": "com.microsoft.VSCode", "WarpTerminal": "dev.warp.Warp-Stable", "ghostty": "com.mitchellh.ghostty"]
            guard let id = bundleID ?? termProgram.flatMap({ known[$0] }) else { return nil }
            self.bundleID = id
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        }

        var icon: NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }

        func activate() { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate() }
    }

    @Published private(set) var app: SourceApp?

    @Published private(set) var working = false
    @Published private(set) var step: Step = .thinking
    @Published private(set) var detail = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var pending: [PermissionRequest] = []
    /// True once the whole body of the front request has been on screen; until then Allow is disabled.
    @Published var reviewed = false
    @Published private(set) var listening = false

    static var socketPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("notch.sock").path
    }

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var watchers: [Int32: DispatchSourceRead] = [:]

    // MARK: Socket server

    func start() {
        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard ok, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listenFD = fd
        listening = true

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard let line = Self.readLine(client), let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                close(client); return
            }
            DispatchQueue.main.async { self?.handle(json, fd: client) }
        }
        src.resume()
        acceptSource = src
    }

    func stop() {
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD); unlink(Self.socketPath) }
        for r in pending { answer(r, .no, reason: "Notch Island quit") }
    }

    /// Reads one newline-terminated JSON message (max 4 MB, 5 s).
    nonisolated private static func readLine(_ fd: Int32) -> Data? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while data.count < 4 << 20 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if buf[n - 1] == UInt8(ascii: "\n") { break }
        }
        return data.isEmpty ? nil : data
    }

    // MARK: Events

    private func handle(_ e: [String: Any], fd: Int32) {
        let event = e["hook_event_name"] as? String ?? ""
        let tool = e["tool_name"] as? String ?? ""
        let input = e["tool_input"] as? [String: Any] ?? [:]
        let project = ((e["cwd"] as? String) as NSString?)?.lastPathComponent ?? ""
        let source = SourceApp(bundleID: e["notch_app_bundle"] as? String, termProgram: e["notch_term_program"] as? String)
        if let source, event != "NotchIslandSnapshot" { app = source }

        switch event {
        case "UserPromptSubmit":
            close(fd)
            startedAt = Date(); working = true; step = .thinking; detail = project
        case "PreToolUse":
            close(fd)
            if !working { working = true; startedAt = startedAt ?? Date() }
            step = Self.step(for: tool)
            detail = Self.shortDetail(tool: tool, input: input)
        case "PermissionRequest":
            // Keep the connection open: notch-hook waits for our answer.
            let (headline, body, note) = Self.describe(tool: tool, input: input)
            let req = PermissionRequest(fd: fd, tool: tool, headline: headline, body: body, note: note, project: project,
                                        always: Self.describeAlways(e["permission_suggestions"] as? [[String: Any]] ?? []),
                                        app: source)
            if pending.isEmpty { reviewed = false }
            pending.append(req)
            watch(req)
        case "Notification":
            close(fd)
            // Permission prompts we're already showing don't need a second bubble.
            if (e["notification_type"] as? String) == "permission_prompt", !pending.isEmpty { break }
            let msg = e["message"] as? String ?? "Claude needs your attention"
            IslandModel.shared.show(Peek(icon: source?.icon.map(Peek.Icon.image) ?? .symbol("bell.fill"),
                                         title: "Claude Code" + (source.map { " · \($0.name)" } ?? ""), subtitle: msg, duration: 4))
        case "NotchIslandSnapshot":
            close(fd)
            Snapshots.prepare(e)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Snapshots.save() }
        case "Stop":
            close(fd)
            let took = startedAt.map { Date().timeIntervalSince($0) }
            working = false; startedAt = nil; detail = ""
            IslandModel.shared.show(Peek(icon: .symbol("checkmark.circle.fill"), title: "Done",
                                         subtitle: took.map { "Took " + Self.duration($0) + (project.isEmpty ? "" : " · \(project)") + (source.map { " · \($0.name)" } ?? "") },
                                         duration: 4))
        default:
            close(fd)
        }
        IslandModel.shared.recompute()
        Hotkeys.shared.update()
    }

    /// If notch-hook goes away (timeout, Ctrl-C), drop the request.
    private func watch(_ r: PermissionRequest) {
        let src = DispatchSource.makeReadSource(fileDescriptor: r.fd, queue: .main)
        src.setEventHandler { [weak self] in
            var b: UInt8 = 0
            if recv(r.fd, &b, 1, MSG_PEEK) <= 0 { MainActor.assumeIsolated { self?.drop(r) } }
        }
        src.resume()
        watchers[r.fd] = src
    }

    private func drop(_ r: PermissionRequest) {
        watchers.removeValue(forKey: r.fd)?.cancel()
        close(r.fd)
        let wasFront = pending.first?.id == r.id
        pending.removeAll { $0.id == r.id }
        if wasFront { reviewed = false }
        IslandModel.shared.recompute()
        Hotkeys.shared.update()
    }

    func answerFront(_ a: Answer) {
        guard let r = pending.first, reviewed || a == .no, a != .always || r.always != nil else { return }
        answer(r, a)
    }

    private func answer(_ r: PermissionRequest, _ a: Answer, reason: String = "Denied from Notch Island") {
        // notch-hook turns "always" into Claude Code's own suggested rule (it has the request JSON).
        let msg = switch a { case .yes: "allow\n"; case .always: "always\n"; case .no: "deny\t\(reason)\n" }
        _ = msg.withCString { write(r.fd, $0, strlen($0)) }
        drop(r)
    }

    // MARK: Text

    private static func step(for tool: String) -> Step {
        switch tool {
        case "Read", "NotebookRead": .reading
        case "Edit", "MultiEdit", "Write", "NotebookEdit": .editing
        case "Bash", "BashOutput", "KillShell": .running
        case "Grep", "Glob", "WebSearch", "WebFetch", "LS": .searching
        case "Task", "Agent", "TodoWrite": .thinking
        default: .other(tool.hasPrefix("mcp__") ? "MCP" : tool)
        }
    }

    private static func shortDetail(tool: String, input: [String: Any]) -> String {
        if let p = input["file_path"] as? String ?? input["notebook_path"] as? String { return (p as NSString).lastPathComponent }
        if let c = input["command"] as? String { return c }
        if let p = input["pattern"] as? String { return p }
        if let q = input["query"] as? String ?? input["url"] as? String { return q }
        return ""
    }

    /// Full text to approve. Bash shows the command exactly; other tools show their whole input.
    private static func describe(tool: String, input: [String: Any]) -> (String, String, String?) {
        if tool == "Bash", let cmd = input["command"] as? String {
            return ("Claude wants to run a command", cmd, input["description"] as? String)
        }
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        let headline: String
        switch tool {
        case "Edit", "MultiEdit": headline = "Claude wants to edit a file"
        case "Write": headline = "Claude wants to write a file"
        case "WebFetch": headline = "Claude wants to fetch a URL"
        default: headline = "Claude wants to use \(tool)"
        }
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(input)"
        return (headline, json, path)
    }

    /// "Bash(npm run lint:*) in this project", like the terminal's "don't ask again" line.
    nonisolated static func describeAlways(_ suggestions: [[String: Any]]) -> String? {
        let parts = suggestions.compactMap { s -> String? in
            let place: String = switch s["destination"] as? String {
            case "session": "for this session"
            case "userSettings": "everywhere"
            default: "in this project"
            }
            if s["type"] as? String == "setMode", let mode = s["mode"] as? String { return "switch to \(mode) mode" }
            guard let rules = s["rules"] as? [[String: Any]], !rules.isEmpty else { return nil }
            let names = rules.map { r in
                (r["toolName"] as? String ?? "tool") + ((r["ruleContent"] as? String).map { "(\($0))" } ?? "")
            }
            return names.joined(separator: ", ") + " " + place
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

// MARK: - Global shortcuts (Carbon hot keys: no Accessibility permission needed)
// ⌃⌥Y = Yes, ⌃⌥A = Always, ⌃⌥N = No. Registered only while a request is open, so they never take keys from other apps otherwise.

@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    /// Set at launch: nil = both free, otherwise a description of the clash.
    private(set) var conflict: String?

    static let combos: [(name: String, key: Int, answer: ClaudeBridge.Answer)] =
        [("⌃⌥Y", kVK_ANSI_Y, .yes), ("⌃⌥N", kVK_ANSI_N, .no), ("⌃⌥A", kVK_ANSI_A, .always)]

    func checkAvailability() {
        var taken: [String] = []
        for (i, c) in Self.combos.enumerated() {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(UInt32(c.key), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x4E49534C, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { UnregisterEventHotKey(ref) } else { taken.append(c.name) }
        }
        conflict = taken.isEmpty ? nil : taken.joined(separator: ", ") + " already used by another app"
    }

    func update() {
        let want = !ClaudeBridge.shared.pending.isEmpty
        if want && refs.isEmpty { register() } else if !want && !refs.isEmpty { unregister() }
    }

    private func register() {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let answer = Hotkeys.combos[Int(id.id)].answer
                MainActor.assumeIsolated { ClaudeBridge.shared.answerFront(answer) }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        for (i, c) in Self.combos.enumerated() {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(c.key), UInt32(controlKey | optionKey),
                                   EventHotKeyID(signature: 0x4E49534C, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref { refs.append(ref) }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

// MARK: - Views

struct ClaudeStatusRow: View {
    @ObservedObject var claude = ClaudeBridge.shared
    @Environment(\.theme) var theme
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: claude.step.symbol).foregroundStyle(theme.accent)
            Text("Claude · \(claude.step.verb)").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            Text(claude.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if let start = claude.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ClaudeBridge.duration(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.secondary)
                }
            }
            if let app = claude.app, let icon = app.icon {
                Button { app.activate() } label: { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    .buttonStyle(.plain).help("Go to \(app.name)")
            }
            WorkingGrid(color: theme.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.tile, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Sizes used to tell whether the whole command has been on screen. (Plain class, not @State:
/// the Command Line Tools don't ship the SwiftUI macro plugin that @State needs.)
@MainActor
final class ScrollCheck: ObservableObject {
    static let shared = ScrollCheck()
    var height: CGFloat = 0
    var textBottom: CGFloat = .infinity
}

/// Shows the whole command. If it's taller than the box, Allow stays disabled until you've scrolled to the end.
struct PermissionView: View {
    let request: ClaudeBridge.PermissionRequest
    let queued: Int
    @ObservedObject var claude = ClaudeBridge.shared
    @Environment(\.theme) var theme
    @ObservedObject private var box = ScrollCheck.shared

    private let maxBox: CGFloat = 320

    /// The end of the text is inside the visible box -> everything has been seen.
    private func check() {
        if box.height > 0, box.textBottom <= box.height + 1, !claude.reviewed { claude.reviewed = true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(theme.accent)
                Text(request.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                if let app = request.app {
                    Button { app.activate() } label: {
                        HStack(spacing: 4) {
                            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                            Text(app.name).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(theme.secondary)
                    .help("Go to \(app.name)")
                }
                Text(request.project + (queued > 0 ? " · \(queued) more waiting" : ""))
                    .font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            if let note = request.note {
                Text(note).font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.vertical) {
                Text(request.body)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("box")).maxY },
                                      action: { box.textBottom = $0; check() })
            }
            .coordinateSpace(name: "box")
            .frame(maxHeight: maxBox)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { box.height = $0; check() })
            .background(theme.tile, in: RoundedRectangle(cornerRadius: 10))
            if let always = request.always {
                Text("Always saves: \(always)").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !claude.reviewed {
                    Label("Scroll to the end to approve", systemImage: "arrow.down")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary)
                }
                Spacer()
                Button { claude.answerFront(.no) } label: { Text("No  ⌃⌥N") }
                    .buttonStyle(FlatButtonStyle())
                if request.always != nil {
                    Button { claude.answerFront(.always) } label: { Text("Always  ⌃⌥A") }
                        .buttonStyle(FlatButtonStyle())
                        .disabled(!claude.reviewed)
                }
                Button { claude.answerFront(.yes) } label: { Text("Yes  ⌃⌥Y") }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                    .disabled(!claude.reviewed)
            }
        }
        .id(request.id)
    }
}
