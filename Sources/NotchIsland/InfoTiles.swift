import AppKit
import Combine
import EventKit
import SwiftUI

// MARK: - Weather (Open-Meteo, free, no key)

@MainActor
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    struct Report { var place: String; var temp: Double; var high: Double; var low: Double; var code: Int; var isDay: Bool }

    @Published private(set) var report: Report?
    @Published private(set) var error: String?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var place: (name: String, lat: Double, lon: Double, query: String)?

    func start() {
        AppSettings.shared.$city.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.place = nil; self?.report = nil; self?.refresh()
        }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    var fahrenheit: Bool { Locale.current.measurementSystem == .us }

    func refresh() {
        let city = AppSettings.shared.city
        guard !city.isEmpty, AppSettings.shared.layout.contains(.weather) else { return }
        Task {
            do {
                if place?.query != city { place = try await geocode(city) }
                guard let place else { return }
                report = try await forecast(place)
                error = nil
            } catch {
                self.error = (error as? WeatherError)?.message ?? "Weather is unavailable right now."
            }
        }
    }

    private struct WeatherError: Error { let message: String }

    private func geocode(_ city: String) async throws -> (String, Double, Double, String) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        struct R: Decodable { struct P: Decodable { var name: String; var latitude: Double; var longitude: Double }; var results: [P]? }
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let p = try JSONDecoder().decode(R.self, from: data).results?.first else {
            throw WeatherError(message: "Couldn't find “\(city)”.")
        }
        return (p.name, p.latitude, p.longitude, city)
    }

    private func forecast(_ p: (name: String, lat: Double, lon: Double, query: String)) async throws -> Report {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(p.lat)), .init(name: "longitude", value: String(p.lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        struct R: Decodable {
            struct Cur: Decodable { var temperature_2m: Double; var weather_code: Int; var is_day: Int }
            struct Day: Decodable { var temperature_2m_max: [Double]; var temperature_2m_min: [Double] }
            var current: Cur; var daily: Day
        }
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let r = try JSONDecoder().decode(R.self, from: data)
        return Report(place: p.name, temp: r.current.temperature_2m,
                      high: r.daily.temperature_2m_max.first ?? r.current.temperature_2m,
                      low: r.daily.temperature_2m_min.first ?? r.current.temperature_2m,
                      code: r.current.weather_code, isDay: r.current.is_day == 1)
    }

    /// WMO weather code -> SF Symbol and words.
    static func describe(_ code: Int, day: Bool) -> (String, String) {
        switch code {
        case 0: (day ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2: (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51...57: ("cloud.drizzle.fill", "Drizzle")
        case 61...67, 80...82: ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86: ("cloud.snow.fill", "Snow")
        case 95...99: ("cloud.bolt.rain.fill", "Thunderstorm")
        default: ("cloud.fill", "—")
        }
    }
}

struct WeatherTile: View {
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    private func on(_ part: String) -> Bool { settings.shows(.weather, part) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileHeader(symbol: "location.fill", title: on("place") ? (weather.report?.place ?? "WEATHER").uppercased() : "WEATHER")
            Spacer(minLength: 0)
            if settings.city.isEmpty {
                Text("Add a city").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Button("Settings…") { SettingsWindowController.shared.show() }.buttonStyle(FlatButtonStyle())
            } else if let r = weather.report {
                let (symbol, words) = WeatherService.describe(r.code, day: r.isDay)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(r.temp.rounded()))°").font(.system(size: scaled(size, 0.23, 20, 44), weight: .semibold))
                        .foregroundStyle(theme.text).minimumScaleFactor(0.6)
                    if on("icon") {
                        Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.system(size: scaled(size, 0.14, 14, 26)))
                    }
                }
                .lineLimit(1)
                if on("condition"), size.height >= 115 {
                    Text(words).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
                }
                if on("highLow"), size.height >= 100 {
                    Text("H \(Int(r.high.rounded()))°  L \(Int(r.low.rounded()))°")
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(theme.secondary).lineLimit(1)
                }
            } else {
                Text(weather.error ?? "Loading…").font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if weather.report == nil { weather.refresh() } }
    }
}

// MARK: - Calendar (EventKit, asked for only when you press the button)

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var next: EKEvent?
    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: Any?

    func requestAccess() {
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { self.status = EKEventStore.authorizationStatus(for: .event); self.startIfAllowed() }
        }
    }

    func startIfAllowed() {
        guard status == .fullAccess, timer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(7 * 86_400), calendars: nil)
        let events = store.events(matching: pred).filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
        next = events.first(where: { !$0.isAllDay }) ?? events.first
    }
}

struct CalendarTile: View {
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileHeader(symbol: "calendar", title: "NEXT")
            Spacer(minLength: 0)
            switch cal.status {
            case .fullAccess:
                if let e = cal.next {
                    Text(e.title ?? "Event").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                        .lineLimit(size.height >= 130 ? 2 : 1)
                    Text(when(e)).font(.system(size: 11)).foregroundStyle(theme.accent).lineLimit(1)
                    if settings.shows(.calendar, "join"), let url = Self.meetingURL(e) {
                        Button("Join") { NSWorkspace.shared.open(url) }.buttonStyle(FlatButtonStyle(prominent: true))
                    } else if settings.shows(.calendar, "location"), size.height >= 110, let loc = e.location, !loc.isEmpty {
                        Text(loc).font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
                    }
                } else {
                    Text("Nothing in the next 7 days").font(.system(size: 12)).foregroundStyle(theme.secondary)
                }
            case .notDetermined:
                Text("Shows your next event. Nothing leaves your Mac.")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Allow") { cal.requestAccess() }.buttonStyle(FlatButtonStyle(prominent: true))
            default:
                Text("Calendar access is off.").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }.buttonStyle(FlatButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { cal.startIfAllowed() }
    }

    private static let meetingPattern = try! NSRegularExpression(
        pattern: #"https://[^\s<>"']*(zoom\.us/j/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|webex\.com/)[^\s<>"']*"#,
        options: .caseInsensitive)

    /// First Zoom / Meet / Teams / Webex link in the event's URL, location or notes.
    static func meetingURL(_ e: EKEvent) -> URL? {
        for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
            let ns = text as NSString
            if let m = meetingPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return URL(string: ns.substring(with: m.range))
            }
        }
        return nil
    }

    private func when(_ e: EKEvent) -> String {
        if e.startDate <= Date() { return "Now · until \(e.endDate.formatted(date: .omitted, time: .shortened))" }
        if e.isAllDay { return e.startDate.formatted(.dateTime.weekday(.wide)) + " · all day" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        let rel = e.startDate.timeIntervalSinceNow < 3 * 3600 ? f.localizedString(for: e.startDate, relativeTo: Date()) + " · " : ""
        let day = Calendar.current.isDateInToday(e.startDate) ? "" : e.startDate.formatted(.dateTime.weekday(.abbreviated)) + " "
        return rel + day + e.startDate.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Focus timer (15 / 25 / 50 min)

@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    var presets: [Int] { TileKind.timerMinutes.filter { AppSettings.shared.shows(.timer, "p\($0)") } }

    @Published private(set) var length: TimeInterval
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var running = false
    private var endsAt: Date?
    private var tick: Timer?

    private init() {
        let minutes = UserDefaults.standard.integer(forKey: "timerMinutes")
        let length = TimeInterval((TileKind.timerMinutes.contains(minutes) ? minutes : 25) * 60)
        self.length = length
        remaining = length
    }

    func setMinutes(_ m: Int) {
        UserDefaults.standard.set(m, forKey: "timerMinutes")
        length = TimeInterval(m * 60)
        reset()
    }

    var remainingText: String {
        let s = Int(remaining.rounded(.up)); return String(format: "%d:%02d", s / 60, s % 60)
    }

    func startPause() {
        if running {
            remaining = max(0, endsAt?.timeIntervalSinceNow ?? remaining)
            running = false; tick?.invalidate(); endsAt = nil
            Awake.hold("focus timer", false)
        } else {
            if remaining <= 0 { remaining = length }
            endsAt = Date().addingTimeInterval(remaining)
            running = true
            Awake.hold("focus timer", true) // countdown and "Focus done" stay on time
            tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        IslandModel.shared.recompute()
    }

    func reset() {
        tick?.invalidate(); running = false; endsAt = nil; remaining = length
        Awake.hold("focus timer", false)
        IslandModel.shared.recompute()
    }

    private func update() {
        guard let endsAt else { return }
        remaining = max(0, endsAt.timeIntervalSinceNow)
        if remaining == 0 {
            reset()
            remaining = 0
            NSSound(named: "Glass")?.play()
            IslandModel.shared.show(Peek(icon: .symbol("checkmark.circle.fill"), title: "Focus done", subtitle: "\(Int(length / 60)) minutes. Take a break.", duration: 4))
        }
    }
}

struct TimerTile: View {
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    private func on(_ part: String) -> Bool { settings.shows(.timer, part) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileHeader(symbol: "timer", title: "FOCUS")
            Spacer(minLength: 0)
            Text(timer.remainingText).font(.system(size: scaled(size, 0.21, 18, 44), weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.text).minimumScaleFactor(0.6).lineLimit(1)
            if on("progress") { ProgressBar(value: 1 - timer.remaining / timer.length) }
            let idle = !timer.running && timer.remaining == timer.length
            if idle, size.height >= 125, !timer.presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(timer.presets, id: \.self) { m in
                            Button("\(m)") { timer.setMinutes(m) }
                                .buttonStyle(FlatButtonStyle(prominent: Int(timer.length / 60) == m, compact: true))
                        }
                    }
                }
                .frame(height: 22)
            }
            // Words when there's room, icons when narrow.
            ViewThatFits(in: .horizontal) {
                controls(words: true)
                controls(words: false)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func controls(words: Bool) -> some View {
        let idle = !timer.running && timer.remaining == timer.length
        return HStack(spacing: 6) {
            Button { timer.startPause() } label: {
                if words { Text(timer.running ? "Pause" : "Start") } else { Image(systemName: timer.running ? "pause.fill" : "play.fill") }
            }
            .buttonStyle(FlatButtonStyle(prominent: true))
            .help(timer.running ? "Pause" : "Start")
            if on("reset") {
                Button { timer.reset() } label: {
                    if words { Text("Reset") } else { Image(systemName: "arrow.counterclockwise") }
                }
                .buttonStyle(FlatButtonStyle()).disabled(idle).help("Reset")
            }
        }
        .fixedSize()
    }
}
