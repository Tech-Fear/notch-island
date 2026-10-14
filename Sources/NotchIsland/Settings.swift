import AppKit
import ServiceManagement
import SwiftUI

enum TileKind: String, CaseIterable, Identifiable, Codable {
    case music, weather, calendar, timer, volume, shelf, clipboard, controls, battery, reminders
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
        }
    }
}

/// One widget on a carousel page. A widget may appear on several pages.
struct Placement: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: TileKind
    var width: Int // units: a page's width is shared out by units
}

/// Everything the visual editor changes.
struct IslandLayout: Codable, Equatable {
    var pages: [[Placement]]
    var islandWidth: Double = 700
    var tileHeight: Double = 132
    var corner: Double = 14
    var spacing: Double = 10

    static let widthRange = 1...4

    static let standard = IslandLayout(pages: [
        [.init(kind: .music, width: 2), .init(kind: .weather, width: 1), .init(kind: .calendar, width: 1), .init(kind: .timer, width: 1)],
        [.init(kind: .music, width: 2), .init(kind: .volume, width: 1), .init(kind: .shelf, width: 1)],
        [.init(kind: .controls, width: 2), .init(kind: .battery, width: 1), .init(kind: .reminders, width: 1), .init(kind: .clipboard, width: 1)],
    ])

    static let newInV3: [TileKind] = [.clipboard, .controls, .battery, .reminders]

    func contains(_ kind: TileKind) -> Bool { pages.contains { $0.contains { $0.kind == kind } } }
    func page(of kind: TileKind) -> Int? { pages.firstIndex { $0.contains { $0.kind == kind } } }
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

    private init() {
        theme = ThemeName(rawValue: d.string(forKey: "theme") ?? "") ?? .darkMatte
        if let data = d.data(forKey: "layout"), let saved = try? JSONDecoder().decode(IslandLayout.self, from: data) {
            var l = saved
            // Layouts saved before these widgets existed get them once, on a new page.
            if !d.bool(forKey: "layoutV3"), !IslandLayout.newInV3.contains(where: saved.contains) {
                l.pages.append(IslandLayout.standard.pages[2])
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
