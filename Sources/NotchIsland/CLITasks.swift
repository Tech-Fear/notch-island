import AppKit
import SwiftUI

/// Commands run with `notch run` and progress sent with `notch progress`.
@MainActor
final class TaskCenter: ObservableObject {
    static let shared = TaskCenter()

    struct Item: Identifiable {
        let id: String
        var title: String
        var progress: Double?          // 0...1; nil = running, no percentage
        let started: Date
        var updated: Date
        var app: ClaudeBridge.SourceApp?
    }

    @Published private(set) var items: [Item] = []
    private var sweeper: Timer?

    func start(id: String, title: String, app: ClaudeBridge.SourceApp?) {
        items.removeAll { $0.id == id }
        items.append(Item(id: id, title: title, progress: nil, started: Date(), updated: Date(), app: app))
        changed()
    }

    /// `code` nil: the `notch run` process went away without reporting (closed terminal, killed).
    func end(id: String, code: Int?, seconds: Double?) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        let took = seconds.map { "Took " + ClaudeBridge.duration($0) } ?? ""
        let (symbol, title) = switch code {
        case 0?: ("checkmark.circle.fill", "Done")
        case let c?: ("xmark.octagon.fill", "Failed (exit \(c))")
        case nil: ("stop.circle.fill", "Stopped")
        }
        IslandModel.shared.show(Peek(icon: .symbol(symbol), title: "\(title) · \(item.title)", subtitle: took, duration: 4))
        changed()
    }

    /// `notch progress 40 "Importing"`, or `notch progress done "Importing"`.
    func progress(title: String, value: String) {
        let id = "progress:" + title
        if value == "done" { end(id: id, code: 0, seconds: items.first { $0.id == id }.map { Date().timeIntervalSince($0.started) }); return }
        let fraction = min(max((Double(value) ?? 0) / 100, 0), 1)
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].progress = fraction; items[i].updated = Date()
        } else {
            items.append(Item(id: id, title: title, progress: fraction, started: Date(), updated: Date(), app: nil))
        }
        changed()
    }

    private func changed() {
        IslandModel.shared.recompute()
        // Progress that stops arriving is dropped after 10 minutes.
        if sweeper == nil, items.contains(where: { $0.id.hasPrefix("progress:") }) {
            sweeper = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.items.removeAll { $0.id.hasPrefix("progress:") && Date().timeIntervalSince($0.updated) > 600 }
                    if !self.items.contains(where: { $0.id.hasPrefix("progress:") }) { t.invalidate(); self.sweeper = nil }
                    IslandModel.shared.recompute()
                }
            }
        }
    }
}

struct TaskRow: View {
    let item: TaskCenter.Item
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(theme.accent)
            Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let p = item.progress {
                ProgressBar(value: p).frame(width: 80)
                Text("\(Int(p * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ClaudeBridge.duration(ctx.date.timeIntervalSince(item.started)))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.secondary)
                }
                WorkingGrid(color: theme.accent)
            }
            if let app = item.app, let icon = app.icon {
                Button { app.activate() } label: { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    .buttonStyle(.plain).help("Go to \(app.name)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.tile, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension ClaudeBridge {
    /// Messages from the `notch` command.
    func handleCLI(_ e: [String: Any], fd: Int32, source: SourceApp?) {
        let action = e["action"] as? String ?? ""
        let title = (e["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "view":
            close(fd)
            if let path = e["path"] as? String { ViewerWindow.shared.open(file: URL(fileURLWithPath: path)) }
        case "say":
            close(fd)
            IslandModel.shared.show(Peek(icon: source?.icon.map(Peek.Icon.image) ?? .symbol("text.bubble.fill"),
                                         title: title.isEmpty ? "Notch" : title, subtitle: source?.name, duration: 4))
        case "done", "fail":
            close(fd)
            IslandModel.shared.show(Peek(icon: .symbol(action == "done" ? "checkmark.circle.fill" : "xmark.octagon.fill"),
                                         title: title.isEmpty ? (action == "done" ? "Done" : "Failed") : title,
                                         subtitle: source?.name, duration: 4))
        case "progress":
            close(fd)
            TaskCenter.shared.progress(title: title.isEmpty ? "Progress" : title, value: e["value"] as? String ?? "0")
        case "task-start":
            // The `notch run` connection stays open until the command ends.
            let id = "run:\(fd)"
            TaskCenter.shared.start(id: id, title: title, app: source)
            followTask(fd: fd, id: id)
        case "ask":
            // Same Yes/No flow (and shortcuts) as a Claude permission request.
            let detail = (e["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            askFromCLI(fd: fd, question: title.isEmpty ? "Continue?" : title, detail: detail, source: source)
        default:
            close(fd)
        }
        IslandModel.shared.recompute()
    }

    private func followTask(fd: Int32, id: String) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var buffer = Data()
        src.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            MainActor.assumeIsolated {
                guard n > 0 else { // closed without reporting
                    src.cancel(); close(fd)
                    TaskCenter.shared.end(id: id, code: nil, seconds: nil)
                    return
                }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[(nl + 1)...])
                    guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          msg["action"] as? String == "task-end" else { continue }
                    src.cancel(); close(fd)
                    TaskCenter.shared.end(id: id, code: msg["code"] as? Int, seconds: msg["seconds"] as? Double)
                    return
                }
            }
        }
        src.resume()
    }
}

// MARK: - Everything running, one at a time with ‹ › to switch

/// Which running item the Activity row shows (no @State without Xcode's macro plugin).
@MainActor
final class ActivityPager: ObservableObject {
    static let shared = ActivityPager()
    @Published var index = 0
}

struct ActivityBar: View {
    @ObservedObject var claude = ClaudeBridge.shared
    @ObservedObject var tasks = TaskCenter.shared
    @ObservedObject var pager = ActivityPager.shared
    @Environment(\.theme) var theme

    private enum Entry: Identifiable {
        case claude(ClaudeBridge.Session), task(TaskCenter.Item)
        var id: String {
            switch self {
            case .claude(let s): "claude:" + s.id
            case .task(let t): t.id
            }
        }
    }

    private var entries: [Entry] {
        claude.sessions.sorted { $0.startedAt < $1.startedAt }.map(Entry.claude) + tasks.items.map(Entry.task)
    }

    var body: some View {
        let all = entries
        if !all.isEmpty {
            let i = min(pager.index, all.count - 1)
            HStack(spacing: 6) {
                Group {
                    switch all[i] {
                    case .claude(let s): ClaudeStatusRow(session: s)
                    case .task(let t): TaskRow(item: t)
                    }
                }
                .id(all[i].id)
                .transition(.opacity)
                if all.count > 1 {
                    HStack(spacing: 2) {
                        TileButton(symbol: "chevron.left", size: 10) { step(-1, all.count) }
                        Text("\(i + 1)/\(all.count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(theme.secondary)
                        TileButton(symbol: "chevron.right", size: 10) { step(1, all.count) }
                    }
                    .help("\(all.count) running: switch between them")
                }
            }
        }
    }

    private func step(_ d: Int, _ count: Int) {
        withAnimation(.easeInOut(duration: 0.15)) { pager.index = (min(pager.index, count - 1) + d + count) % count }
    }
}
