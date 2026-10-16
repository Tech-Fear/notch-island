import AppKit
import EventKit
import IOKit.ps
import IOKit.pwr_mgt
import Network
import SwiftUI

// MARK: - Clipboard history (off until you turn it on; kept in memory only, never saved or sent)

@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    @Published private(set) var items: [String] = []
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "clipboard")
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() { if enabled { watch() } }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "clipboard")
        if on { watch() } else { timer?.invalidate(); timer = nil; items = [] }
    }

    private func watch() {
        lastCount = -1 // also pick up what's on the clipboard right now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        // Password managers mark secrets as concealed/transient: never keep those.
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]),
              let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > 10 { items.removeLast() }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        IslandModel.shared.show(Peek(icon: .symbol("doc.on.clipboard"), title: "Copied", subtitle: String(text.prefix(40)), duration: 2))
    }

    func clear() { items = [] }
}

struct ClipboardTile: View {
    @ObservedObject var clip = ClipboardHistory.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TileHeader(symbol: "doc.on.clipboard", title: "CLIPBOARD")
                Spacer()
                if clip.enabled, !clip.items.isEmpty, AppSettings.shared.shows(.clipboard, "clear") {
                    Button { clip.clear() } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary).help("Clear history")
                }
            }
            if !clip.enabled {
                Spacer(minLength: 0)
                Hint("Keeps the last 10 things you copy, only in memory. Skips passwords.")
                Button("Turn On") { clip.setEnabled(true) }.buttonStyle(FlatButtonStyle(prominent: true))
            } else if clip.items.isEmpty {
                Spacer(minLength: 0)
                Text("Copy something and it shows up here.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Spacer(minLength: 0)
            } else {
                if let latest = clip.items.first { ClipToolsRow(text: latest) }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(clip.items, id: \.self) { text in
                            Text(text.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(theme.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                                .onTapGesture { clip.copy(text) }
                                .help("Click to copy again")
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Controls: brightness, keyboard backlight, keep awake, dark mode, desktop icons

/// Display brightness and keyboard backlight have no public API on Apple Silicon; these are the
/// private frameworks Control Center uses. If a macOS update removes them, the sliders just hide.
private enum Brightness {
    private static let display = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static func get() -> Float? {
        guard let s = dlsym(display, "DisplayServicesGetBrightness") else { return nil }
        var v: Float = 0
        return unsafeBitCast(s, to: GetFn.self)(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    static func set(_ v: Float) {
        guard let s = dlsym(display, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(s, to: SetFn.self)(CGMainDisplayID(), v)
    }

    private static let keyboardClient: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static var keyboardID: UInt64? {
        guard let c = keyboardClient,
              let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return ids.first?.uint64Value
    }

    static func keyboard() -> Float? {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let c = keyboardClient, let id = keyboardID, c.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, id)
    }

    static func setKeyboard(_ v: Float) {
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let c = keyboardClient, let id = keyboardID, c.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        _ = unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, v, id)
    }
}

private enum Appearance {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private typealias GetFn = @convention(c) () -> Bool
    private typealias SetFn = @convention(c) (Bool) -> Void

    static var isDark: Bool {
        if let s = dlsym(skyLight, "SLSGetAppearanceThemeLegacy") { return unsafeBitCast(s, to: GetFn.self)() }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// false when the private call isn't available on this macOS.
    static func set(dark: Bool) -> Bool {
        guard let s = dlsym(skyLight, "SLSSetAppearanceThemeLegacy") else { return false }
        unsafeBitCast(s, to: SetFn.self)(dark)
        return true
    }
}

@MainActor
final class SystemControls: ObservableObject {
    static let shared = SystemControls()

    @Published private(set) var brightness: Float?
    @Published private(set) var keyboard: Float?
    @Published private(set) var awake = false
    @Published private(set) var dark = false
    @Published private(set) var desktopIcons = true
    private var assertion: IOPMAssertionID = 0

    private var themeObserver: Any?

    func refresh() {
        if themeObserver == nil { // dark mode changed anywhere (Control Center, System Settings)
            themeObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        brightness = Brightness.get()
        keyboard = Brightness.keyboard()
        dark = Appearance.isDark
        desktopIcons = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool ?? true
    }

    func setBrightness(_ v: Float) { Brightness.set(max(v, 0.02)); brightness = v }
    func setKeyboard(_ v: Float) { Brightness.setKeyboard(v); keyboard = v }

    /// Keeps the display awake, like `caffeinate -d`, until you turn it off or quit.
    func toggleAwake() {
        if awake {
            IOPMAssertionRelease(assertion)
        } else {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Notch Island: keep awake" as CFString, &assertion)
        }
        awake.toggle()
    }

    /// Switches directly (SkyLight, like Control Center: no permission). If that private call is
    /// gone, asks System Events instead, which shows one Automation prompt the first time.
    func toggleDark() {
        if Appearance.set(dark: !dark) { dark.toggle(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")?
                .executeAndReturnError(&err)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    /// Finder has no live switch for this: the setting is written and Finder restarts (windows reopen).
    func toggleDesktopIcons() {
        let show = !desktopIcons
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "defaults write com.apple.finder CreateDesktop -bool \(show) && killall Finder"]
        try? p.run()
        desktopIcons = show
    }
}

struct ControlsTile: View {
    @ObservedObject var c = SystemControls.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    private func on(_ part: String) -> Bool { settings.shows(.controls, part) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TileHeader(symbol: "slider.horizontal.3", title: "CONTROLS")
            Spacer(minLength: 0)
            // Very small: the toggles matter most, the slider goes.
            if on("brightness"), size.height >= 120 || size.width >= 150, let b = c.brightness {
                row("sun.max.fill") { FlatSlider(value: Double(b)) { c.setBrightness(Float($0)) } }
            }
            // The keyboard slider goes first when the widget is short.
            if on("keyboard"), size.height >= 120, let k = c.keyboard {
                row("light.max") { FlatSlider(value: Double(k)) { c.setKeyboard(Float($0)) } }
            }
            // Wide: icon + word. Narrow: icons only.
            ViewThatFits(in: .horizontal) {
                toggles(labels: true)
                toggles(labels: false)
                VStack(alignment: .leading, spacing: 4) { toggles(labels: false, only: ["awake", "dark"]); toggles(labels: false, only: ["icons"]) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { c.refresh() }
    }

    private func row(_ symbol: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(theme.secondary).frame(width: 16)
            content()
        }
    }

    private func toggles(labels: Bool, only: Set<String>? = nil) -> some View {
        let on = { (p: String) in self.on(p) && (only?.contains(p) ?? true) }
        return HStack(spacing: 6) {
            if on("awake") { toggle("cup.and.saucer.fill", "Awake", c.awake, labels) { c.toggleAwake() } }
            if on("dark") { toggle("moon.fill", "Dark", c.dark, labels) { c.toggleDark() } }
            if on("icons") { toggle("menubar.dock.rectangle", "Icons", c.desktopIcons, labels) { c.toggleDesktopIcons() } }
        }
    }

    private func toggle(_ symbol: String, _ title: String, _ on: Bool, _ labels: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if labels { Label(title, systemImage: symbol).labelStyle(.titleAndIcon).lineLimit(1) } else { Image(systemName: symbol) }
        }
        .buttonStyle(FlatButtonStyle(prominent: on, compact: !labels))
        .fixedSize()
        .help(title == "Icons" ? "Show or hide desktop icons (restarts Finder)" : title == "Awake" ? "Keep the display awake" : "Dark mode")
    }
}

// MARK: - Battery: level, time left, top energy users

@MainActor
final class BatteryInfo: ObservableObject {
    static let shared = BatteryInfo()

    @Published private(set) var level: Int?
    @Published private(set) var charging = false
    @Published private(set) var onAC = false
    @Published private(set) var timeText: String?
    @Published private(set) var topApps: [(name: String, power: Double)] = []
    private var lastTop = Date.distantPast

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            level = d[kIOPSCurrentCapacityKey] as? Int
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = charging ? d[kIOPSTimeToFullChargeKey] as? Int : d[kIOPSTimeToEmptyKey] as? Int
            if let m = minutes, m > 0 {
                timeText = "\(m / 60)h \(m % 60)m " + (charging ? "to full" : "left")
            } else {
                timeText = onAC ? (charging ? "Charging" : "On power adapter") : "Estimating…"
            }
        }
        if Date().timeIntervalSince(lastTop) > 30 { lastTop = Date(); loadTopApps() }
    }

    /// `top` sorted by its POWER column (second sample; the first has no rates). Takes ~2 s, off the main thread.
    private func loadTopApps() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
            p.arguments = ["-l", "2", "-n", "4", "-o", "power", "-stats", "command,power"]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let block = text.components(separatedBy: "COMMAND").last ?? ""
            let rows = block.split(separator: "\n").dropFirst().compactMap { line -> (String, Double)? in
                let parts = line.split(separator: " ")
                guard parts.count >= 2, let power = Double(parts.last!) else { return nil }
                return (parts.dropLast().joined(separator: " "), power)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.topApps = Array(rows.prefix(3)) } }
        }
    }
}

struct BatteryTile: View {
    @ObservedObject var b = BatteryInfo.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileHeader(symbol: b.charging ? "battery.100percent.bolt" : "battery.75percent", title: "BATTERY")
            Spacer(minLength: 0)
            if let level = b.level {
                Text("\(level)%").font(.system(size: scaled(size, 0.2, 18, 40), weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.text).minimumScaleFactor(0.6).lineLimit(1)
                if settings.shows(.battery, "time") {
                    Text(b.timeText ?? "").font(.system(size: 11)).foregroundStyle(theme.accent).lineLimit(1)
                }
                // As many energy users as fit.
                let rows = settings.shows(.battery, "apps") ? max(0, Int((size.height - 95) / 14)) : 0
                ForEach(b.topApps.prefix(rows), id: \.name) { app in
                    Text(app.name).font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
                }
            } else {
                Text("No battery").font(.system(size: 12)).foregroundStyle(theme.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { b.refresh() }
        .help("Top energy users right now, from `top`")
    }
}

// MARK: - Reminders (EventKit; asked for only when you press Allow)

@MainActor
final class RemindersService: ObservableObject {
    static let shared = RemindersService()

    @Published private(set) var status = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var items: [EKReminder] = []
    private let store = EKEventStore()
    private var observer: Any?

    func requestAccess() {
        store.requestFullAccessToReminders { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.status = EKEventStore.authorizationStatus(for: .reminder)
                self.refresh()
            } }
        }
    }

    /// Incomplete reminders due by the end of today (overdue included).
    func refresh() {
        guard status == .fullAccess else { return }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date())
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        store.fetchReminders(matching: pred) { found in
            let sorted = (found ?? []).sorted {
                ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.items = Array(sorted.prefix(6)) } }
        }
    }

    func complete(_ r: EKReminder) {
        r.isCompleted = true
        try? store.save(r, commit: true)
        refresh()
    }
}

struct RemindersTile: View {
    @ObservedObject var rem = RemindersService.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileHeader(symbol: "checklist", title: "TODAY")
            switch rem.status {
            case .fullAccess:
                if rem.items.isEmpty {
                    Spacer(minLength: 0)
                    Text("Nothing due today").font(.system(size: 12)).foregroundStyle(theme.secondary)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rem.items, id: \.calendarItemIdentifier) { r in
                                HStack(spacing: 6) {
                                    if AppSettings.shared.shows(.reminders, "complete") {
                                        Button { rem.complete(r) } label: {
                                            Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(theme.accent)
                                        }
                                        .buttonStyle(.plain).help("Mark as done")
                                    }
                                    Text(r.title ?? "Reminder").font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            case .notDetermined:
                Spacer(minLength: 0)
                Hint("Shows reminders due today. Nothing leaves your Mac.")
                Button("Allow") { rem.requestAccess() }.buttonStyle(FlatButtonStyle(prominent: true))
            default:
                Spacer(minLength: 0)
                Text("Reminders access is off.").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }.buttonStyle(FlatButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { rem.refresh() }
    }
}

// MARK: - Network changes (peek with the connection type and local IP)

@MainActor
final class NetworkWatcher {
    static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private var last: String?

    func start() {
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.update(path) } }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func update(_ path: NWPath) {
        let kind: String
        if path.status != .satisfied { kind = "Offline" }
        else if path.usesInterfaceType(.wifi) { kind = "Wi-Fi" }
        else if path.usesInterfaceType(.wiredEthernet) { kind = "Ethernet" }
        else if path.usesInterfaceType(.cellular) { kind = "Cellular" }
        else { kind = "Network" }
        let ip = path.status == .satisfied ? Self.localIPv4() : nil
        let key = kind + (ip ?? "")
        defer { last = key }
        guard let last, last != key else { return } // no bubble at launch
        IslandModel.shared.show(Peek(icon: .symbol(kind == "Offline" ? "wifi.slash" : kind == "Wi-Fi" ? "wifi" : "network"),
                                     title: kind == "Offline" ? "Offline" : "\(kind) connected", subtitle: ip))
    }

    /// First IPv4 address of an active en* interface.
    private static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: a.ifa_name).hasPrefix("en"), a.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

// MARK: - Headphones / speakers connected (from the audio device list: no Bluetooth permission)

enum DeviceBattery {
    /// Battery text for a Bluetooth device, from `system_profiler` (no permission needed). Off the main thread.
    static func lookup(_ name: String, done: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var text: String?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                text = battery(for: name, in: (try? JSONSerialization.jsonObject(with: data)) ?? [:])
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }

    /// Finds the entry named `name` anywhere in the JSON and joins its batteryLevel fields ("L 80% · R 75% · Case 40%").
    private static func battery(for name: String, in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let entry = dict[name] as? [String: Any] {
                let labels = ["Left": "L", "Right": "R", "Case": "Case", "Main": ""]
                let parts = entry.keys.sorted().compactMap { key -> String? in
                    guard key.contains("batteryLevel"), let v = entry[key] as? String else { return nil }
                    let label = labels.first { key.hasSuffix($0.key) }?.value ?? ""
                    return label.isEmpty ? v : "\(label) \(v)"
                }
                if !parts.isEmpty { return parts.joined(separator: " · ") }
            }
            for v in dict.values { if let r = battery(for: name, in: v) { return r } }
        } else if let array = json as? [Any] {
            for v in array { if let r = battery(for: name, in: v) { return r } }
        }
        return nil
    }
}
