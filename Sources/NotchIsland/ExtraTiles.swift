import AppKit
import Darwin
import SwiftUI

// MARK: - System stats (CPU, memory, disk, network; no permission)

@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    @Published private(set) var cpu: Double = 0           // 0...1
    @Published private(set) var memUsed: Double = 0       // bytes
    let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskFree: Double = 0      // bytes
    @Published private(set) var down: Double = 0          // bytes per second
    @Published private(set) var up: Double = 0

    private var timer: Timer?
    private var lastTicks: [UInt32]?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        // CPU: busy share of the ticks since the last sample.
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &load, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }) == KERN_SUCCESS {
            let t = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3] // user, system, idle, nice
            if let l = lastTicks {
                let d = zip(t, l).map { Double($0 &- $1) }
                let total = d.reduce(0, +)
                if total > 0 { cpu = (total - d[2]) / total }
            }
            lastTicks = t
        }
        // Memory in use, as Activity Monitor counts it: active + wired + compressed.
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &vm, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) } }) == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            memUsed = Double(UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = v.volumeAvailableCapacityForImportantUsage { diskFree = Double(free) }
        // Network: bytes in/out on en* interfaces since the last sample.
        var rx: UInt64 = 0, tx: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
                guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK),
                      String(cString: p.pointee.ifa_name).hasPrefix("en"),
                      let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
                rx += UInt64(data.pointee.ifi_ibytes); tx += UInt64(data.pointee.ifi_obytes)
            }
            freeifaddrs(list)
        }
        let now = Date()
        if let l = lastNet, rx >= l.rx, tx >= l.tx {
            let dt = max(now.timeIntervalSince(l.at), 0.1)
            down = Double(rx - l.rx) / dt; up = Double(tx - l.tx) / dt
        }
        lastNet = (rx, tx, now)
    }
}

func byteText(_ b: Double, perSecond: Bool = false) -> String {
    let f = ByteCountFormatter()
    f.countStyle = perSecond ? .binary : .file
    f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
    return f.string(fromByteCount: Int64(b)) + (perSecond ? "/s" : "")
}

struct StatsTile: View {
    @ObservedObject var s = SystemStats.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    private func on(_ p: String) -> Bool { settings.shows(.stats, p) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TileHeader(symbol: "cpu", title: "SYSTEM")
            Spacer(minLength: 0)
            if on("cpu") { row("CPU", "CPU", "\(Int(s.cpu * 100))%", s.cpu) }
            if on("memory") { row("Memory", "RAM", byteText(s.memUsed), s.memUsed / s.memTotal) }
            if on("disk"), size.height >= 120 { row("Disk free", "Disk", byteText(s.diskFree), nil) }
            if on("network"), size.height >= 110 {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Label(byteText(s.down, perSecond: true), systemImage: "arrow.down")
                        Spacer(minLength: 4)
                        Label(byteText(s.up, perSecond: true), systemImage: "arrow.up")
                    }
                    Label(byteText(s.down, perSecond: true), systemImage: "arrow.down")
                }
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(theme.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { s.start() }
    }

    private func row(_ title: String, _ short: String, _ value: String, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Full label, then a short one; the value is never cut.
            ViewThatFits(in: .horizontal) {
                line(title, value)
                line(short, value)
                Text(value).foregroundStyle(theme.text).monospacedDigit().minimumScaleFactor(0.7)
            }
            .font(.system(size: 10)).lineLimit(1)
            if let fraction { ProgressBar(value: fraction) }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        // ViewThatFits only picks this when label + value fit side by side; then it spans the row.
        HStack(spacing: 4) {
            Text(label).foregroundStyle(theme.secondary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(theme.text).monospacedDigit()
        }
    }
}

// MARK: - App launcher

@MainActor
final class Launcher: ObservableObject {
    static let shared = Launcher()
    @Published private(set) var apps: [String] { didSet { UserDefaults.standard.set(apps, forKey: "launcherApps") } }
    @Published var editing = false

    private init() {
        apps = UserDefaults.standard.stringArray(forKey: "launcherApps")
            ?? ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", "com.apple.systempreferences"]
    }

    func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    func open(_ id: String) {
        guard let url = url(id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        IslandModel.shared.holdOpen(true)
        panel.begin { r in
            IslandModel.shared.holdOpen(false)
            guard r == .OK else { return }
            for u in panel.urls { if let id = Bundle(url: u)?.bundleIdentifier, !self.apps.contains(id) { self.apps.append(id) } }
        }
    }

    func remove(_ id: String) { apps.removeAll { $0 == id } }
}

struct LauncherTile: View {
    @ObservedObject var launcher = Launcher.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TileHeader(symbol: "square.grid.2x2", title: "APPS")
                Spacer()
                Button { launcher.add() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add apps…")
                Button { launcher.editing.toggle() } label: { Image(systemName: launcher.editing ? "checkmark" : "pencil") }
                    .buttonStyle(.plain).help(launcher.editing ? "Done" : "Remove apps")
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                    ForEach(launcher.apps, id: \.self) { id in
                        if let url = launcher.url(id) {
                            Button { launcher.editing ? launcher.remove(id) : launcher.open(id) } label: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
                                    .overlay(alignment: .topTrailing) {
                                        if launcher.editing {
                                            Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                                .foregroundStyle(theme.text, theme.secondary.opacity(0.7)).offset(x: 4, y: -4)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(FileManager.default.displayName(atPath: url.path))
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Countdown

struct Countdown: Codable, Equatable {
    var title: String
    var date: Date
}

/// "12 days" + "4 h 3 m to Launch", or "Launch was 2 days ago".
func countdownText(to c: Countdown, from now: Date) -> (big: String, small: String) {
    let s = Int(c.date.timeIntervalSince(now))
    let a = abs(s)
    let days = a / 86_400, hours = a % 86_400 / 3600, minutes = a % 3600 / 60
    let big = days > 0 ? "\(days) day\(days == 1 ? "" : "s")" : hours > 0 ? "\(hours) h \(minutes) m" : "\(minutes) min"
    if s < 0 { return (big, "\(c.title) was \(big.lowercased()) ago") }
    return (big, (days > 0 ? "\(hours) h \(minutes) m to " : "to ") + c.title)
}

struct CountdownTile: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileHeader(symbol: "hourglass", title: "COUNTDOWN")
            Spacer(minLength: 0)
            if let c = settings.countdown {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let t = countdownText(to: c, from: ctx.date)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.big).font(.system(size: scaled(size, 0.2, 18, 36), weight: .semibold).monospacedDigit())
                            .foregroundStyle(theme.text).minimumScaleFactor(0.6).lineLimit(1)
                        Text(t.small).font(.system(size: 11)).foregroundStyle(theme.accent).lineLimit(2)
                    }
                }
            } else {
                Hint("Count down to a date.")
                Button("Set…") { SettingsWindowController.shared.show() }.buttonStyle(FlatButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Color picker (the system magnifier; no permission)

func hexString(_ color: NSColor) -> String? {
    guard let c = color.usingColorSpace(.sRGB) else { return nil }
    let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()).clamped(0, 255) }
    return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

@MainActor
final class ColorPicks: ObservableObject {
    static let shared = ColorPicks()
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentColors") ?? [] {
        didSet { UserDefaults.standard.set(recent, forKey: "recentColors") }
    }
    private let sampler = NSColorSampler()

    func pick() {
        sampler.show { color in
            guard let color, let hex = hexString(color) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.copy(hex) } }
        }
    }

    func copy(_ hex: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        recent.removeAll { $0 == hex }
        recent.insert(hex, at: 0)
        if recent.count > 8 { recent.removeLast() }
        IslandModel.shared.show(Peek(icon: .symbol("eyedropper"), title: "Copied \(hex)", subtitle: nil, duration: 2))
    }
}

struct ColorPickerTile: View {
    @ObservedObject var picks = ColorPicks.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TileHeader(symbol: "eyedropper", title: "COLOR")
            HStack(alignment: .top, spacing: 8) {
                // Labelled when there's room, a round icon button when narrow.
                ViewThatFits(in: .horizontal) {
                    Button { picks.pick() } label: { Label("Pick", systemImage: "eyedropper.halffull").fixedSize() }
                        .buttonStyle(FlatButtonStyle(prominent: true))
                    Button { picks.pick() } label: { Image(systemName: "eyedropper.halffull") }
                        .buttonStyle(FlatButtonStyle(prominent: true, compact: true))
                }
                .fixedSize()
                .help("Pick a colour anywhere on screen")
                if picks.recent.isEmpty {
                    Hint("Then click any colour on screen.")
                } else {
                    swatches
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var swatches: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 16), spacing: 4)], spacing: 4) {
                ForEach(picks.recent, id: \.self) { hex in
                    Button { picks.copy(hex) } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0))
                            .frame(height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain).help("Copy \(hex)")
                }
            }
    }
}

// MARK: - Quick notes (stored in ~/Library/Application Support/NotchIsland/notes.json)

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updated = Date()
}

@MainActor
final class Notes: ObservableObject {
    static let shared = Notes()
    @Published private(set) var notes: [Note] = []
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchIsland/notes.json")

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Note].self, from: data) { notes = saved }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(notes).write(to: file, options: .atomic)
    }

    func upsert(_ note: Note) {
        let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes.removeAll { $0.id == note.id }
        if !trimmed.isEmpty { var n = note; n.updated = Date(); notes.insert(n, at: 0) }
        save()
    }

    func delete(_ id: UUID) { notes.removeAll { $0.id == id }; save() }
}

/// The note being edited (no @State without Xcode's macro plugin).
@MainActor
final class NoteDraft: ObservableObject {
    static let shared = NoteDraft()
    @Published var note = Note(text: "")
}

struct NoteEditorView: View {
    @ObservedObject var draft = NoteDraft.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft.note.text).font(.system(size: 13)).frame(minHeight: 160)
            HStack {
                Button("Delete", role: .destructive) { Notes.shared.delete(draft.note.id); NSApp.keyWindow?.close() }
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut("w", modifiers: .command)
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

/// Typing needs keyboard focus, which the island never takes, so notes open in a small window.
@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate {
    static let shared = NoteWindowController()
    private var window: NSWindow?

    func edit(_ note: Note?) {
        if let window, window.isVisible { Notes.shared.upsert(NoteDraft.shared.note); window.close() }
        NoteDraft.shared.note = note ?? Note(text: "")
        let w = NSWindow(contentViewController: NSHostingController(rootView: NoteEditorView()))
        w.title = note == nil ? "New Note" : "Note"
        w.styleMask = [.titled, .closable]
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.orderFrontRegardless()
        w.makeKey()
    }

    func windowWillClose(_ notification: Notification) { Notes.shared.upsert(NoteDraft.shared.note) }
}

struct NotesTile: View {
    @ObservedObject var notes = Notes.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TileHeader(symbol: "note.text", title: "NOTES")
                Spacer()
                Button { NoteWindowController.shared.edit(nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .bold)).foregroundStyle(theme.secondary).help("New note")
            }
            if notes.notes.isEmpty {
                Spacer(minLength: 0)
                Hint("Press + to jot something down.", always: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes.notes) { n in
                            Button { NoteWindowController.shared.edit(n) } label: {
                                Text(n.text.components(separatedBy: .newlines).first ?? "")
                                    .font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(theme.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Quick actions

enum QuickAction: String, CaseIterable, Identifiable {
    case lock, sleep, screenshot, mission
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lock: "Lock"
        case .sleep: "Display off"
        case .screenshot: "Screenshot"
        case .mission: "Mission Control"
        }
    }
    var symbol: String {
        switch self {
        case .lock: "lock.fill"
        case .sleep: "moon.zzz.fill"
        case .screenshot: "camera.viewfinder"
        case .mission: "rectangle.3.group"
        }
    }

    /// Locking has no public API; this is the call the Control Center "Lock Screen" item uses.
    private static let lockScreen: (@convention(c) () -> Int32)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let s = dlsym(h, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(s, to: (@convention(c) () -> Int32).self)
    }()

    var available: Bool { self != .lock || Self.lockScreen != nil }

    func run() {
        switch self {
        case .lock: _ = Self.lockScreen?()
        case .sleep:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        case .screenshot: Self.openApp("com.apple.screenshot.launcher")
        case .mission: Self.openApp("com.apple.exposelauncher")
        }
    }

    private static func openApp(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension ActionsTile {
    fileprivate func button(_ a: QuickAction, labels: Bool, minWidth: CGFloat) -> some View {
        Button { a.run() } label: {
            VStack(spacing: 3) {
                Image(systemName: a.symbol).font(.system(size: labels ? 14 : 12))
                if labels { Text(a.title).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .foregroundStyle(theme.text)
            .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: labels ? 30 : 22)
            .padding(.vertical, labels ? 4 : 2)
            .background(theme.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).help(a.title)
    }
}

struct ActionsTile: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        let actions = QuickAction.allCases.filter { $0.available && settings.shows(.actions, $0.rawValue) }
        let tall = size.height >= 125
        VStack(alignment: .leading, spacing: 6) {
            TileHeader(symbol: "bolt.fill", title: "ACTIONS")
            Spacer(minLength: 0)
            // Wide: one row. Otherwise a 2x2 grid; labels only when tall.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { ForEach(actions) { button($0, labels: tall, minWidth: 58) } }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(actions) { button($0, labels: tall, minWidth: 0) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Recent downloads (draggable, like the Shelf)

@MainActor
final class RecentDownloads: ObservableObject {
    static let shared = RecentDownloads()
    @Published private(set) var files: [URL] = []
    /// Reading ~/Downloads makes macOS ask once, so it waits until you press Show.
    @Published private(set) var allowed = UserDefaults.standard.bool(forKey: "downloadsAllowed")

    func allow() {
        allowed = true
        UserDefaults.standard.set(true, forKey: "downloadsAllowed")
        refresh()
    }

    func refresh() {
        guard allowed, let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        func added(_ u: URL) -> Date {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
        }
        files = Array(items.sorted { added($0) > added($1) }.prefix(12))
    }
}

struct DownloadsTile: View {
    @ObservedObject var dl = RecentDownloads.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileHeader(symbol: "arrow.down.circle", title: "DOWNLOADS")
            if !dl.allowed {
                Spacer(minLength: 0)
                Hint("Your latest downloads, ready to drag.")
                Button("Show") { dl.allow() }.buttonStyle(FlatButtonStyle(prominent: true))
            } else if dl.files.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing in Downloads.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size.width < 140 ? 40 : 64), spacing: 6)], spacing: 6) {
                        ForEach(dl.files, id: \.self) { url in
                            VStack(spacing: 3) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                                if settings.shows(.downloads, "names"), size.height >= 100, size.width >= 140 {
                                    Text(url.lastPathComponent).font(.system(size: 9)).foregroundStyle(theme.text)
                                        .lineLimit(1).truncationMode(.middle).frame(width: 58)
                                }
                            }
                            .allowsHitTesting(false)
                            .background(FileDragSource(url: url, onRemove: nil))
                            .help(url.path)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { dl.refresh() }
    }
}
