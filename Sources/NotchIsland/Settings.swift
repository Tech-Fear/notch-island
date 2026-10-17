import AppKit
import ServiceManagement
import SwiftUI

enum TileKind: String, CaseIterable, Identifiable, Codable {
    case music, weather, calendar, timer, volume, shelf, clipboard, controls, battery, reminders
    case stats, launcher, countdown, colorPicker, notes, actions, downloads
    case ports, git, docker
    case authenticator, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: "Now Playing"
        case .weather: "Weather"
        case .calendar: "Calendar"
        case .timer: "Focus Timer"
        case .volume: "Volume"
        case .shelf: "File Shelf"
        case .clipboard: "Clipboard"
        case .controls: "Controls"
        case .battery: "Battery"
        case .reminders: "Reminders"
        case .stats: "System Stats"
        case .launcher: "App Launcher"
        case .countdown: "Countdown"
        case .colorPicker: "Color Picker"
        case .notes: "Quick Notes"
        case .actions: "Quick Actions"
        case .downloads: "Recent Downloads"
        case .ports: "Ports"
        case .git: "Git"
        case .docker: "Docker"
        case .authenticator: "Authenticator"
        case .tools: "Dev Toolbox"
        }
    }
    var symbol: String {
        switch self {
        case .music: "music.note"
        case .weather: "cloud.sun"
        case .calendar: "calendar"
        case .timer: "timer"
        case .volume: "speaker.wave.2"
        case .shelf: "tray"
        case .clipboard: "doc.on.clipboard"
        case .controls: "slider.horizontal.3"
        case .battery: "battery.75percent"
        case .reminders: "checklist"
        case .stats: "cpu"
        case .launcher: "square.grid.2x2"
        case .countdown: "hourglass"
        case .colorPicker: "eyedropper"
        case .notes: "note.text"
        case .actions: "bolt.fill"
        case .downloads: "arrow.down.circle"
        case .ports: "network"
        case .git: "arrow.triangle.branch"
        case .docker: "shippingbox"
        case .authenticator: "key.fill"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

extension TileKind {
    /// Menu-bar groups, by what the widgets are for.
    enum Group: String, CaseIterable {
        case media = "Media", today = "Today", files = "Files", system = "System", developer = "Developer"
        var symbol: String {
            switch self {
            case .media: "music.note"
            case .today: "calendar"
            case .files: "tray"
            case .system: "gearshape"
            case .developer: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    var group: Group {
        switch self {
        case .music, .volume: .media
        case .weather, .calendar, .reminders, .timer, .countdown, .notes: .today
        case .shelf, .downloads, .clipboard: .files
        case .controls, .battery, .stats, .actions, .launcher: .system
        case .tools, .authenticator, .git, .ports, .docker, .colorPicker: .developer
        }
    }
}

/// A part of a widget that can be switched on or off in Edit Layout (gear button).
struct WidgetPart: Identifiable {
    let id: String
    let title: String
    var on = true // default
}

extension TileKind {
    static let timerMinutes = [5, 10, 15, 20, 25, 30, 45, 50, 60, 90]

    var parts: [WidgetPart] {
        switch self {
        case .music: [.init(id: "cover", title: "Cover"), .init(id: "lyrics", title: "Lyrics"),
                      .init(id: "progress", title: "Progress bar"), .init(id: "times", title: "Elapsed / total time"),
                      .init(id: "previous", title: "Previous button"), .init(id: "appIcon", title: "App icon")]
        case .weather: [.init(id: "place", title: "City name"), .init(id: "icon", title: "Weather icon"),
                        .init(id: "condition", title: "Condition"), .init(id: "highLow", title: "High and low")]
        case .calendar: [.init(id: "join", title: "Join button"), .init(id: "location", title: "Location")]
        case .timer: [.init(id: "progress", title: "Progress bar"), .init(id: "reset", title: "Reset button")]
            + Self.timerMinutes.map { .init(id: "p\($0)", title: "\($0) min preset", on: [15, 25, 50].contains($0)) }
        case .volume: [.init(id: "mute", title: "Mute button"), .init(id: "percent", title: "Percentage"),
                       .init(id: "device", title: "Output picker")]
        case .shelf: [.init(id: "names", title: "File names")]
        case .clipboard: [.init(id: "clear", title: "Clear button")]
        case .controls: [.init(id: "brightness", title: "Display brightness"), .init(id: "keyboard", title: "Keyboard backlight"),
                         .init(id: "awake", title: "Keep awake"), .init(id: "dark", title: "Dark mode"),
                         .init(id: "icons", title: "Desktop icons")]
        case .battery: [.init(id: "time", title: "Time left"), .init(id: "apps", title: "Top energy apps")]
        case .reminders: [.init(id: "complete", title: "Tick to complete")]
        case .stats: [.init(id: "cpu", title: "CPU"), .init(id: "memory", title: "Memory"),
                      .init(id: "disk", title: "Disk free"), .init(id: "network", title: "Network speed")]
        case .actions: QuickAction.allCases.map { .init(id: $0.rawValue, title: $0.title) }
        case .downloads: [.init(id: "names", title: "File names")]
        case .launcher, .countdown, .colorPicker, .notes, .ports, .git, .docker, .authenticator, .tools: []
        }
    }
}

/// One widget on a carousel page. A widget may appear several times, on one page or many.
struct Placement: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: TileKind
    var width: Int // columns: a page's width is shared out by columns
    var height = 1 // rows: widgets one row tall stack up next to taller ones

    init(kind: TileKind, width: Int, height: Int = 1) { self.kind = kind; self.width = width; self.height = height }

    // Layouts saved before rows existed have no height.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(TileKind.self, forKey: .kind)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1
    }
}

/// Where each widget of a page sits: a grid as many rows tall as its tallest widget, with the fewest
/// columns that hold everything. Widgets fill it in order, left to right, top to bottom, each in the
/// first gap it fits (so two short widgets stack beside a tall one). One-row pages work as before.
struct PageGrid {
    var columns = 1, rows = 1
    var cells: [UUID: (col: Int, row: Int)] = [:]

    init(_ tiles: [Placement]) {
        guard !tiles.isEmpty else { return }
        rows = tiles.map(\.height).max()!
        let area = tiles.reduce(0) { $0 + $1.width * $1.height }
        var cols = max(tiles.map(\.width).max()!, (area + rows - 1) / rows)
        while true { // ends by the time every widget fits in one row of columns
            if let fit = Self.pack(tiles, columns: cols, rows: rows) { columns = cols; cells = fit; return }
            cols += 1
        }
    }

    private static func pack(_ tiles: [Placement], columns: Int, rows: Int) -> [UUID: (col: Int, row: Int)]? {
        var used = Array(repeating: Array(repeating: false, count: columns), count: rows)
        var out: [UUID: (col: Int, row: Int)] = [:]
        func free(_ c: Int, _ r: Int, _ t: Placement) -> Bool {
            (r..<r + t.height).allSatisfy { y in (c..<c + t.width).allSatisfy { !used[y][$0] } }
        }
        next: for t in tiles { // columns >= every width and rows >= every height, so the ranges are valid
            for r in 0...(rows - t.height) {
                for c in 0...(columns - t.width) where free(c, r, t) {
                    for y in r..<r + t.height { for x in c..<c + t.width { used[y][x] = true } }
                    out[t.id] = (c, r)
                    continue next
                }
            }
            return nil
        }
        return out
    }
}

/// Everything the visual editor changes.
struct IslandLayout: Codable, Equatable {
    var pages: [[Placement]]
    var islandWidth: Double = 700
    var tileHeight: Double = 132
    var corner: Double = 14
    var spacing: Double = 10

    static let widthRange = 1...4
    static let heightRange = 1...3

    /// The default: one page per job, as tuned on the developer's Mac.
    static let standard = IslandLayout(pages: [
        [.init(kind: .weather, width: 1), .init(kind: .calendar, width: 1), .init(kind: .timer, width: 1), .init(kind: .battery, width: 1)],
        [.init(kind: .controls, width: 1), .init(kind: .shelf, width: 1)],
        [.init(kind: .volume, width: 2), .init(kind: .music, width: 2)],
        [.init(kind: .downloads, width: 1), .init(kind: .stats, width: 1)],
        [.init(kind: .actions, width: 1), .init(kind: .ports, width: 1), .init(kind: .git, width: 1)],
        [.init(kind: .tools, width: 1, height: 2), .init(kind: .authenticator, width: 1, height: 2)],
    ], islandWidth: 677, tileHeight: 100)

    /// The pages older versions added one by one (used only to upgrade layouts saved by them).
    static let earlierPages = IslandLayout(pages: [
        [.init(kind: .music, width: 2), .init(kind: .weather, width: 1), .init(kind: .calendar, width: 1), .init(kind: .timer, width: 1)],
        [.init(kind: .music, width: 2), .init(kind: .volume, width: 1), .init(kind: .shelf, width: 1)],
        [.init(kind: .controls, width: 2), .init(kind: .battery, width: 1), .init(kind: .reminders, width: 1), .init(kind: .clipboard, width: 1)],
        [.init(kind: .stats, width: 1), .init(kind: .launcher, width: 2), .init(kind: .actions, width: 1)],
        [.init(kind: .notes, width: 1), .init(kind: .countdown, width: 1), .init(kind: .colorPicker, width: 1), .init(kind: .downloads, width: 1)],
        [.init(kind: .git, width: 1), .init(kind: .ports, width: 1), .init(kind: .docker, width: 1)],
        [.init(kind: .authenticator, width: 2), .init(kind: .tools, width: 1)],
    ])

    static let newInV3: [TileKind] = [.clipboard, .controls, .battery, .reminders]
    static let newInV4: [TileKind] = [.stats, .launcher, .countdown, .colorPicker, .notes, .actions, .downloads]
    static let newInV5: [TileKind] = [.ports, .git, .docker]
    static let newInV6: [TileKind] = [.authenticator, .tools]

    func contains(_ kind: TileKind) -> Bool { pages.contains { $0.contains { $0.kind == kind } } }
    func page(of kind: TileKind) -> Int? { pages.firstIndex { $0.contains { $0.kind == kind } } }
}

/// Where the island appears when there's more than one display.
enum IslandScreens: String, CaseIterable, Identifiable {
    case followMouse, all, chosen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .followMouse: "Follows the Mouse"
        case .all: "On Every Screen"
        case .chosen: "One Screen I Choose"
        }
    }
    var detail: String {
        switch self {
        case .followMouse: "One island, on whichever screen your pointer is on."
        case .all: "An island on each screen with the same status; a question shows on all, answering on one clears it everywhere."
        case .chosen: "Always on the screen you pick below."
        }
    }
}

/// All user settings, stored in UserDefaults. Nothing is synced anywhere.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var theme: ThemeName { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var layout: IslandLayout { didSet { d.set(try? JSONEncoder().encode(layout), forKey: "layout") } }
    @Published var city: String { didSet { d.set(city, forKey: "city") } }
    /// Overrides of WidgetPart defaults, keyed "kind.part".
    @Published var parts: [String: Bool] { didSet { d.set(parts, forKey: "widgetParts") } }
    @Published var focusPeeks: Bool { didSet { d.set(focusPeeks, forKey: "focusPeeks") } }
    @Published var spotifyCovers: Bool { didSet { d.set(spotifyCovers, forKey: "spotifyCovers") } }
    /// Folder the Git widget watches; nil = follow the latest Claude Code session.
    @Published var gitRepo: String? { didSet { d.set(gitRepo, forKey: "gitRepo") } }
    /// New screenshots are added to the Shelf (opt-in: reading their folder asks for access once).
    @Published var screenshotsToShelf: Bool { didSet { d.set(screenshotsToShelf, forKey: "screenshotsToShelf") } }
    @Published var countdown: Countdown? { didSet { d.set(try? JSONEncoder().encode(countdown), forKey: "countdown") } }
    @Published var islandScreens: IslandScreens { didSet { d.set(islandScreens.rawValue, forKey: "islandScreens") } }
    /// The display picked for `.chosen` (its name); nil: the screen with the notch, else the main screen.
    @Published var islandScreenName: String? { didSet { d.set(islandScreenName, forKey: "islandScreenName") } }

    private init() {
        theme = ThemeName(rawValue: d.string(forKey: "theme") ?? "") ?? .darkMatte
        if let data = d.data(forKey: "layout"), let saved = try? JSONDecoder().decode(IslandLayout.self, from: data) {
            var l = saved
            // Layouts saved before these widgets existed get them once, on a new page.
            if !d.bool(forKey: "layoutV3"), !IslandLayout.newInV3.contains(where: saved.contains) {
                l.pages.append(IslandLayout.earlierPages.pages[2])
            }
            if !d.bool(forKey: "layoutV4"), !IslandLayout.newInV4.contains(where: saved.contains) {
                l.pages += IslandLayout.earlierPages.pages[3...4]
            }
            if !d.bool(forKey: "layoutV5"), !IslandLayout.newInV5.contains(where: saved.contains) {
                l.pages.append(IslandLayout.earlierPages.pages[5])
            }
            if !d.bool(forKey: "layoutV6"), !IslandLayout.newInV6.contains(where: saved.contains) {
                l.pages.append(IslandLayout.earlierPages.pages[6])
            }
            layout = l
        } else {
            // First run of this version: page 1 keeps the tiles and order chosen before the carousel existed.
            var l = IslandLayout.standard
            if let order = d.stringArray(forKey: "tileOrder")?.compactMap(TileKind.init(rawValue:)) {
                let hidden = Set(d.stringArray(forKey: "hiddenTiles") ?? [])
                l.pages[0] = order.filter { !hidden.contains($0.rawValue) }.map { .init(kind: $0, width: $0 == .music ? 2 : 1) }
            }
            layout = l
        }
        d.set(true, forKey: "layoutV3")
        d.set(true, forKey: "layoutV4")
        d.set(true, forKey: "layoutV5")
        d.set(true, forKey: "layoutV6")
        islandScreens = IslandScreens(rawValue: d.string(forKey: "islandScreens") ?? "") ?? .followMouse
        islandScreenName = d.string(forKey: "islandScreenName")
        gitRepo = d.string(forKey: "gitRepo")
        screenshotsToShelf = d.bool(forKey: "screenshotsToShelf")
        countdown = d.data(forKey: "countdown").flatMap { try? JSONDecoder().decode(Countdown.self, from: $0) }
        parts = d.dictionary(forKey: "widgetParts") as? [String: Bool] ?? [:]
        city = d.string(forKey: "city") ?? ""
        focusPeeks = d.bool(forKey: "focusPeeks")
        spotifyCovers = d.bool(forKey: "spotifyCovers")
    }

    var themeColors: Theme { .named(theme) }
    func shows(_ kind: TileKind, _ part: String) -> Bool {
        parts["\(kind.rawValue).\(part)"] ?? kind.parts.first { $0.id == part }?.on ?? true
    }

    func setPart(_ kind: TileKind, _ part: String, _ on: Bool) { parts["\(kind.rawValue).\(part)"] = on }

    /// Menu show/hide: hiding removes the widget from every page; showing adds it to page 1.
    func toggle(_ tile: TileKind) {
        if layout.contains(tile) {
            for i in layout.pages.indices { layout.pages[i].removeAll { $0.kind == tile } }
        } else {
            layout.pages[0].append(.init(kind: tile, width: tile == .music ? 2 : 1))
        }
    }

    // MARK: Launch at login (off unless the user turns it on)

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }
}

/// Text being typed in the City field (kept outside the view: no @State without Xcode's macro plugin).
@MainActor
final class CityDraft: ObservableObject {
    static let shared = CityDraft()
    @Published var text = AppSettings.shared.city
    @Published var countdownTitle = AppSettings.shared.countdown?.title ?? ""
    @Published var countdownDate = AppSettings.shared.countdown?.date ?? Date().addingTimeInterval(7 * 86_400)
}

// MARK: - Settings window (city + theme; layout has its own editor)

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var draft = CityDraft.shared

    var body: some View {
        Form {
            Section("Weather") {
                HStack {
                    TextField("City", text: $draft.text, prompt: Text("e.g. Bengaluru"))
                        .onSubmit(saveCity)
                    Button("Save", action: saveCity).disabled(draft.text == settings.city)
                }
                Text("Only the city name and its coordinates are sent to Open-Meteo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Countdown") {
                TextField("Title", text: $draft.countdownTitle, prompt: Text("e.g. Launch"))
                DatePicker("Date", selection: $draft.countdownDate)
                HStack {
                    Button("Save") {
                        settings.countdown = Countdown(title: draft.countdownTitle.isEmpty ? "the date" : draft.countdownTitle,
                                                       date: draft.countdownDate)
                    }
                    if settings.countdown != nil { Button("Clear") { settings.countdown = nil } }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut("w", modifiers: .command)
                    Button("") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction).hidden()
                }
            }
            Section("Layout") {
                Button("Edit Layout…") { LayoutEditorController.shared.show() }
            }
            Section("Screens") {
                Picker("Island", selection: $settings.islandScreens) {
                    ForEach(IslandScreens.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.islandScreens.detail).font(.caption).foregroundStyle(.secondary)
                if settings.islandScreens == .chosen {
                    Picker("Screen", selection: $settings.islandScreenName) {
                        Text("Automatic (the notch screen, else the main one)").tag(String?.none)
                        ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(ThemeName.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }

    private func saveCity() {
        settings.city = draft.text.trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Notch Island Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}
