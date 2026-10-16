import AppKit
import SwiftUI

/// Runs a command-line tool off the main thread and returns (exit code, stdout).
func runTool(_ path: String, _ args: [String]) async -> (code: Int32, out: String) {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .utility).async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { cont.resume(returning: (-1, "")); return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
    }
}

/// Polls `refresh` every few seconds while a widget is on a page.
@MainActor
class Poller: ObservableObject {
    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil }
    func refresh() {}
}

// MARK: - Ports: local servers that are listening

struct ListeningPort: Identifiable, Equatable {
    let port: Int
    let pid: Int32
    let command: String
    var id: Int { port }
}

/// Parses `lsof -nP -iTCP -sTCP:LISTEN -F pcn` (p = pid, c = command, n = address:port lines).
func parseListeningPorts(_ out: String) -> [ListeningPort] {
    var pid: Int32 = 0, command = "", seen = Set<Int>(), result: [ListeningPort] = []
    for line in out.split(separator: "\n") {
        guard let tag = line.first else { continue }
        let value = String(line.dropFirst())
        switch tag {
        case "p": pid = Int32(value) ?? 0
        case "c": command = value
        case "n":
            guard let port = value.split(separator: ":").last.flatMap({ Int($0) }), seen.insert(port).inserted else { continue }
            result.append(ListeningPort(port: port, pid: pid, command: command))
        default: break
        }
    }
    return result.sorted { $0.port < $1.port }
}

@MainActor
final class PortsWatcher: Poller {
    static let shared = PortsWatcher()
    @Published private(set) var ports: [ListeningPort] = []
    @Published var confirmStop: Int?   // port awaiting a second click

    override func refresh() {
        Task {
            // lsof without sudo only lists your own processes, which is what we want.
            let r = await runTool("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
            let list = parseListeningPorts(r.out)
            if list != ports { ports = list }
        }
    }

    func open(_ p: ListeningPort) { NSWorkspace.shared.open(URL(string: "http://localhost:\(p.port)")!) }

    /// First click arms, second click (within 3 s) sends SIGTERM, like Ctrl-C would.
    func stop(_ p: ListeningPort) {
        if confirmStop == p.port {
            kill(p.pid, SIGTERM)
            confirmStop = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        } else {
            confirmStop = p.port
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.confirmStop == p.port { self.confirmStop = nil } }
        }
    }
}

struct PortsTile: View {
    @ObservedObject var w = PortsWatcher.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileHeader(symbol: "network", title: "PORTS")
            if w.ports.isEmpty {
                Spacer(minLength: 0)
                Hint("No local servers listening.", always: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(w.ports) { p in
                            HStack(spacing: 6) {
                                Text(":" + String(p.port)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(theme.text)
                                Text(p.command).font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
                                Spacer(minLength: 2)
                                TileButton(symbol: "safari", size: 11) { w.open(p) }.help("Open http://localhost:\(p.port)")
                                Button { w.stop(p) } label: {
                                    if w.confirmStop == p.port {
                                        Text("Stop?").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                                            .padding(.horizontal, 5).padding(.vertical, 2).background(Color.red.opacity(0.8), in: Capsule())
                                    } else {
                                        Image(systemName: "stop.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                                    }
                                }
                                .buttonStyle(.plain).help("Stop \(p.command) (click twice)")
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { w.start() } // also when only shown in a preview or added later
    }
}

// MARK: - Git: the repo Claude is working in (or one you pick)

struct GitStatus: Equatable {
    var branch = ""
    var ahead = 0
    var behind = 0
    var changed = 0
    var untracked = 0
    var hasUpstream = false
}

/// Parses `git status --porcelain=v2 --branch`.
func parseGitStatus(_ out: String) -> GitStatus {
    var s = GitStatus()
    for line in out.split(separator: "\n") {
        if line.hasPrefix("# branch.head ") { s.branch = String(line.dropFirst("# branch.head ".count)) }
        else if line.hasPrefix("# branch.upstream ") { s.hasUpstream = true }
        else if line.hasPrefix("# branch.ab ") {
            for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                if part.hasPrefix("+") { s.ahead = Int(part.dropFirst()) ?? 0 }
                if part.hasPrefix("-") { s.behind = Int(part.dropFirst()) ?? 0 }
            }
        }
        else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") { s.changed += 1 }
        else if line.hasPrefix("? ") { s.untracked += 1 }
    }
    return s
}

@MainActor
final class GitWatcher: Poller {
    static let shared = GitWatcher()
    @Published private(set) var status: GitStatus?
    @Published private(set) var repo: String?
    @Published private(set) var note: String?

    /// A folder you picked wins; otherwise the latest Claude Code session's folder.
    var folder: String? { AppSettings.shared.gitRepo ?? ClaudeBridge.shared.lastCwd }

    override func refresh() {
        guard let folder else { status = nil; repo = nil; note = "Pick a repo, or start Claude Code in one."; return }
        Task {
            let top = await runTool("/usr/bin/git", ["-C", folder, "rev-parse", "--show-toplevel"])
            guard top.code == 0 else { status = nil; repo = nil; note = "\((folder as NSString).lastPathComponent) isn't a git repo."; return }
            let r = await runTool("/usr/bin/git", ["-C", folder, "status", "--porcelain=v2", "--branch"])
            repo = (top.out.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
            status = parseGitStatus(r.out)
            note = nil
        }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Watch"
        NSApp.activate(ignoringOtherApps: true)
        IslandModel.shared.holdOpen(true)
        panel.begin { r in
            IslandModel.shared.holdOpen(false)
            if r == .OK, let url = panel.url { AppSettings.shared.gitRepo = url.path; self.refresh() }
        }
    }

    func followClaude() { AppSettings.shared.gitRepo = nil; refresh() }
}

struct GitTile: View {
    @ObservedObject var git = GitWatcher.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                TileHeader(symbol: "arrow.triangle.branch", title: git.repo?.uppercased() ?? "GIT")
                Spacer()
                Button { git.pick() } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("Watch a folder…")
                if settings.gitRepo != nil {
                    Button { git.followClaude() } label: { Image(systemName: "sparkle") }.buttonStyle(.plain).help("Follow Claude's folder")
                }
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
            Spacer(minLength: 0)
            if let s = git.status {
                Text(s.branch).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if s.ahead > 0 { Label("\(s.ahead)", systemImage: "arrow.up") }
                    if s.behind > 0 { Label("\(s.behind)", systemImage: "arrow.down") }
                    if !s.hasUpstream { Label("not pushed yet", systemImage: "icloud.slash") }
                    else if s.ahead == 0, s.behind == 0 { Label("in sync", systemImage: "checkmark") }
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.accent)
                Text(s.changed + s.untracked == 0 ? "Clean" : "\(s.changed) changed · \(s.untracked) new")
                    .font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
            } else if let note = git.note {
                Hint(note, always: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { git.start() } // also when only shown in a preview or added later
    }
}

// MARK: - Docker containers

struct Container: Identifiable, Equatable {
    let id: String
    let name: String
    let running: Bool
    let status: String
}

/// Parses `docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}'`.
func parseContainers(_ out: String) -> [Container] {
    out.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4 else { return nil }
        return Container(id: f[0], name: f[1], running: f[2] == "running", status: f[3])
    }
    .sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }
}

@MainActor
final class DockerWatcher: Poller {
    static let shared = DockerWatcher()
    @Published private(set) var containers: [Container] = []
    @Published private(set) var note: String?

    private var docker: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbstack/bin/docker").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    override func refresh() {
        guard let docker else { containers = []; note = "Docker isn't installed."; return }
        Task {
            let r = await runTool(docker, ["ps", "-a", "--format", "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}"])
            if r.code != 0 { containers = []; note = "Docker isn't running."; return }
            let list = parseContainers(r.out)
            note = list.isEmpty ? "No containers." : nil
            if list != containers { containers = list }
        }
    }

    func toggle(_ c: Container) {
        guard let docker else { return }
        Task {
            _ = await runTool(docker, [c.running ? "stop" : "start", c.id])
            refresh()
        }
    }
}

struct DockerTile: View {
    @ObservedObject var d = DockerWatcher.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileHeader(symbol: "shippingbox", title: "DOCKER")
            if let note = d.note, d.containers.isEmpty {
                Spacer(minLength: 0)
                Hint(note, always: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(d.containers) { c in
                            HStack(spacing: 6) {
                                Circle().fill(c.running ? Color.green : theme.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                Text(c.name).font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                                Spacer(minLength: 2)
                                TileButton(symbol: c.running ? "stop.fill" : "play.fill", size: 10) { d.toggle(c) }
                                    .help(c.running ? "Stop \(c.name)" : "Start \(c.name)")
                            }
                            .help(c.status)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { d.start() } // also when only shown in a preview or added later
    }
}

// MARK: - Clipboard tools: one-click conversions for the latest copy

enum ClipTool: String, CaseIterable {
    case json = "Pretty JSON", base64 = "Decode Base64", jwt = "Decode JWT", time = "Timestamp → date"

    /// nil when the tool doesn't apply to this text.
    func apply(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .json: return prettyJSON(t)
        case .base64: return decodeBase64(t)
        case .jwt: return decodeJWT(t)
        case .time: return timestampDate(t)
        }
    }
}

func prettyJSON(_ t: String) -> String? {
    guard t.first == "{" || t.first == "[", let data = t.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(decoding: out, as: UTF8.self)
}

private func base64Data(_ t: String) -> Data? {
    var s = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

/// Only text-looking results: random words aren't Base64 just because they decode.
func decodeBase64(_ t: String) -> String? {
    guard t.count >= 8, t.range(of: #"^[A-Za-z0-9+/_-]+={0,2}$"#, options: .regularExpression) != nil,
          let data = base64Data(t), let s = String(data: data, encoding: .utf8),
          !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return s
}

func decodeJWT(_ t: String) -> String? {
    let parts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let header = base64Data(String(parts[0])).flatMap({ prettyJSON(String(decoding: $0, as: UTF8.self)) }),
          let payload = base64Data(String(parts[1])).flatMap({ prettyJSON(String(decoding: $0, as: UTF8.self)) })
    else { return nil }
    return header + "\n" + payload
}

/// 10-digit seconds or 13-digit milliseconds between 2000 and 2100.
func timestampDate(_ t: String, timeZone: TimeZone = .current) -> String? {
    guard t.range(of: #"^\d{10}(\d{3})?$"#, options: .regularExpression) != nil, let n = Double(t) else { return nil }
    let seconds = t.count == 13 ? n / 1000 : n
    guard (946_684_800...4_102_444_800).contains(seconds) else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    f.timeZone = timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date(timeIntervalSince1970: seconds))
}

/// Chips under the latest clipboard item.
struct ClipToolsRow: View {
    let text: String
    @Environment(\.theme) var theme

    var body: some View {
        let tools = ClipTool.allCases.filter { $0.apply(text) != nil }
        if !tools.isEmpty {
            HStack(spacing: 4) {
                ForEach(tools, id: \.self) { tool in
                    Button(tool.rawValue) {
                        guard let result = tool.apply(text) else { return }
                        ClipboardHistory.shared.copy(result)
                    }
                    .buttonStyle(FlatButtonStyle(compact: true))
                    .font(.system(size: 9))
                }
            }
        }
    }
}
