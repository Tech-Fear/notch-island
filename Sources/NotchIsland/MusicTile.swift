import AppKit
import CryptoKit
import SwiftUI

enum Player: String, CaseIterable {
    case spotify, music
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var title: String { self == .spotify ? "Spotify" : "Apple Music" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

enum AutomationStatus { case granted, needsAsk, denied }

struct NowPlaying: Equatable {
    var player: Player?         // nil: came from the system-wide helper (any app)
    var appName: String
    var appIcon: NSImage?
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var playing: Bool
    var at: Date
    var artworkURL: String
    var cover: NSImage?

    var trackKey: String { "\(appName)|\(title)|\(artist)|\(album)" }
    func position(at now: Date) -> Double {
        playing ? min(duration, position + now.timeIntervalSince(at)) : position
    }
}

struct LyricLine { let time: Double; let text: String }

/// Now Playing for any app comes from the system-wide helper (SystemNowPlaying). If that gives
/// nothing, it falls back to Spotify / Music over AppleScript. AppleScript never launches a player:
/// every script checks `application "X" is running` first, and only open players are polled.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published private(set) var now: NowPlaying?
    @Published private(set) var access: [Player: AutomationStatus] = [:]
    @Published private(set) var lyrics: [LyricLine]?
    @Published private(set) var lyricsNote: String?
    @Published private(set) var runningPlayers: [Player] = []

    private let queue = DispatchQueue(label: "notchisland.applescript")
    private var timer: Timer?
    private var lyricsTask: Task<Void, Never>?
    private var polling = false
    private let system = SystemNowPlaying()
    private var systemNow: NowPlaying?
    /// True once the helper has reported a playing app, i.e. the system-wide path works on this macOS.
    @Published private(set) var systemWorks = false

    func start() {
        system.start { [weak self] np in self?.systemUpdate(np) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stop() {
        system.stop()
        systemNow = nil
        timer?.invalidate(); timer = nil
        now = nil
        IslandModel.shared.recompute()
    }

    // MARK: Permission (asked once per player, only when you press Connect)

    nonisolated private static func automation(_ bundleID: String, ask: Bool) -> OSStatus {
        var addr = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &addr) == noErr else { return -1 }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    nonisolated private static func status(from err: OSStatus) -> AutomationStatus? {
        switch err {
        case noErr: .granted
        case OSStatus(errAEEventWouldRequireUserConsent): .needsAsk
        case OSStatus(errAEEventNotPermitted): .denied
        default: nil // not running or unknown: keep the previous answer
        }
    }

    func connect(_ p: Player) {
        guard p.isRunning else { return }
        queue.async {
            let s = Self.status(from: Self.automation(p.bundleID, ask: true))
            DispatchQueue.main.async { if let s { self.access[p] = s }; self.poll() }
        }
    }

    // MARK: Polling

    private func systemUpdate(_ np: NowPlaying?) {
        systemNow = np
        if let np { systemWorks = true; setNow(np) } else { poll() }
    }

    private func poll() {
        if let systemNow { setNow(systemNow); return } // the helper is the better source
        guard !polling else { return }
        let running = Player.allCases.filter(\.isRunning)
        if running != runningPlayers { runningPlayers = running }
        guard !running.isEmpty else { setNow(nil); return }
        polling = true
        queue.async {
            var results: [NowPlaying] = []
            var statuses: [Player: AutomationStatus] = [:]
            for p in running {
                guard let s = Self.status(from: Self.automation(p.bundleID, ask: false)) else { continue }
                statuses[p] = s
                if s == .granted, let np = Self.readState(p) { results.append(np) }
            }
            DispatchQueue.main.async {
                self.polling = false
                for (p, s) in statuses { if self.access[p] != s { self.access[p] = s } }
                self.setNow(results.first(where: \.playing) ?? results.first)
            }
        }
    }

    private func setNow(_ np: NowPlaying?) {
        var np = np
        let changed = np?.trackKey != now?.trackKey
        if !changed, let cur = now, np?.cover == nil { np?.cover = cur.cover } // the helper sends artwork once per track
        if np != now { now = np }
        if changed {
            lyrics = nil; lyricsNote = nil
            lyricsTask?.cancel()
            if let np { loadExtras(for: np) }
        }
        IslandModel.shared.recompute()
    }

    private func loadExtras(for np: NowPlaying) {
        let key = np.trackKey
        // Cover art: Apple Music hands it over locally. Spotify only gives a URL, so it's fetched
        // only if you turn that on (it contacts Spotify's image server).
        if np.cover != nil {
            // the system helper already sent it
        } else if np.player == .music {
            queue.async {
                let img = Self.musicArtwork()
                DispatchQueue.main.async { if self.now?.trackKey == key { self.now?.cover = img } }
            }
        } else if np.player == .spotify, AppSettings.shared.spotifyCovers, let url = URL(string: np.artworkURL), url.scheme == "https" {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data),
                   self.now?.trackKey == key { self.now?.cover = img }
            }
        }
        lyricsNote = "Looking for lyrics…"
        lyricsTask = Task {
            let result = await Lyrics.fetch(title: np.title, artist: np.artist, album: np.album, duration: np.duration)
            guard !Task.isCancelled, self.now?.trackKey == key else { return }
            switch result {
            case .synced(let lines): self.lyrics = lines; self.lyricsNote = nil
            case .instrumental: self.lyricsNote = "♪ Instrumental"
            case .none: self.lyricsNote = "No synced lyrics"
            }
        }
    }

    func currentLyric(at pos: Double) -> String? {
        guard let lyrics, !lyrics.isEmpty else { return lyricsNote }
        guard let line = lyrics.last(where: { $0.time <= pos + 0.2 }) else { return "♪" }
        return line.text.isEmpty ? "♪" : line.text
    }

    // MARK: Controls

    func playPause() { send("playpause", system: "toggle") }
    func next() { send("next track", system: "next") }
    func previous() { send("previous track", system: "prev") }
    func seek(to seconds: Double) {
        send("set player position to \(Int(seconds))", system: "seek \(seconds)")
        now?.position = seconds; now?.at = Date()
    }

    private func send(_ command: String, system cmd: String) {
        guard let np = now else { return }
        guard let p = np.player else { system.send(cmd); return }
        queue.async {
            _ = Self.run("if application \"\(p.appName)\" is running then tell application \"\(p.appName)\" to \(command)")
            DispatchQueue.main.async { self.poll() }
        }
    }

    // MARK: AppleScript (always on the same serial queue)

    nonisolated private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    nonisolated private static func readState(_ p: Player) -> NowPlaying? {
        let durationExpr = p == .spotify ? "(duration of t) / 1000" : "duration of t"
        let artExpr = p == .spotify ? "artwork url of t" : "\"\""
        let src = """
        if application "\(p.appName)" is running then
          tell application "\(p.appName)"
            with timeout of 3 seconds
              try
                set st to player state as string
                if st is "stopped" then return {"stopped"}
                set t to current track
                return {st, name of t, artist of t, album of t, \(durationExpr), player position, \(artExpr)}
              on error
                return {"stopped"}
              end try
            end timeout
          end tell
        end if
        return {"closed"}
        """
        guard let d = run(src), d.numberOfItems >= 7 else { return nil }
        func s(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func n(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        return NowPlaying(player: p, appName: p.title, appIcon: nil, title: s(2), artist: s(3), album: s(4), duration: n(5),
                          position: n(6), playing: s(1) == "playing", at: Date(), artworkURL: s(7))
    }

    nonisolated private static func musicArtwork() -> NSImage? {
        let src = """
        if application "Music" is running then
          tell application "Music"
            with timeout of 3 seconds
              try
                return data of artwork 1 of current track
              end try
            end timeout
          end tell
        end if
        """
        guard let d = run(src) else { return nil }
        return NSImage(data: d.data)
    }
}

// MARK: - LRCLIB (free, no key) with a local cache

enum Lyrics {
    enum Result { case synced([LyricLine]), instrumental, none }

    private struct Cached: Codable { var synced: String?; var instrumental: Bool; var fetched: Date }
    private struct Item: Decodable { var syncedLyrics: String?; var instrumental: Bool?; var duration: Double? }

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.local.NotchIsland/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Result {
        guard !title.isEmpty else { return .none }
        let key = SHA256.hash(data: Data("\(title)|\(artist)|\(album)|\(Int(duration))".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let file = cacheDir.appendingPathComponent(key + ".json")

        // Hits are kept forever; misses are retried after a day.
        if let data = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Cached.self, from: data),
           c.synced != nil || c.instrumental || Date().timeIntervalSince(c.fetched) < 86_400 {
            return result(c)
        }

        var item = await get(title: title, artist: artist, album: album, duration: duration)
        if item?.syncedLyrics == nil, item?.instrumental != true {
            item = await search(title: title, artist: artist, duration: duration) ?? item
        }
        guard !Task.isCancelled else { return .none }
        let c = Cached(synced: item?.syncedLyrics, instrumental: item?.instrumental ?? false, fetched: Date())
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: file) }
        return result(c)
    }

    private static func result(_ c: Cached) -> Result {
        if let s = c.synced { let lines = parse(s); return lines.isEmpty ? .none : .synced(lines) }
        return c.instrumental ? .instrumental : .none
    }

    private static func request(_ path: String, _ items: [URLQueryItem]) -> URLRequest {
        var comps = URLComponents(string: "https://lrclib.net/api/\(path)")!
        comps.queryItems = items
        var req = URLRequest(url: comps.url!, timeoutInterval: 10)
        req.setValue("NotchIsland/0.1 (personal macOS app)", forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func get(title: String, artist: String, album: String, duration: Double) async -> Item? {
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        guard let (data, resp) = try? await URLSession.shared.data(for: request("get", items)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Item.self, from: data)
    }

    private static func search(title: String, artist: String, duration: Double) async -> Item? {
        let items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let (data, resp) = try? await URLSession.shared.data(for: request("search", items)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        let synced = list.filter { $0.syncedLyrics != nil }
        return synced.first { duration <= 0 || abs(($0.duration ?? 0) - duration) < 3 } ?? synced.first
    }

    /// "[01:23.45] text" -> (83.45, "text"). Lines with several timestamps are repeated.
    static func parse(_ lrc: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var out: [LyricLine] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let t = Double(ns.substring(with: m.range(at: 1)))! * 60 + Double(ns.substring(with: m.range(at: 2)))!
                out.append(LyricLine(time: t, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}

// MARK: - System-wide Now Playing helper

/// Runs Helper/nowplaying.m inside Apple's /usr/bin/perl, the only way left to read MediaRemote
/// (any app: Chrome, Safari, Spotify, Music…) since macOS 15.4. Undocumented: a macOS update may
/// close it, in which case it just reports nothing and MusicController falls back to AppleScript.
@MainActor
final class SystemNowPlaying {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var onUpdate: ((NowPlaying?) -> Void)?
    private var restarts = 0

    private static let perl = """
    use DynaLoader;
    my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($l, "ni_nowplaying") or die "symbol";
    DynaLoader::dl_install_xsub("main::np", $s);
    np();
    """

    func start(_ onUpdate: @escaping (NowPlaying?) -> Void) {
        self.onUpdate = onUpdate
        if process == nil { launch() }
    }

    func stop() {
        onUpdate = nil
        try? input?.close() // the helper exits when its stdin closes
        process = nil; input = nil
    }

    func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    private func launch() {
        guard let lib = Bundle.main.path(forResource: "NowPlaying", ofType: "dylib") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.perl, lib]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self.consume(d) } }
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.terminated(p) } }
        }
        do { try p.run() } catch { return }
        process = p
        input = inp.fileHandleForWriting
    }

    private func terminated(_ p: Process) {
        guard p === process, onUpdate != nil else { return }
        process = nil; input = nil
        onUpdate?(nil)
        guard restarts < 5 else { return } // shortcut: gives up after 5 crashes until the app restarts
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.onUpdate != nil, self.process == nil { self.launch() } }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[(nl + 1)...])
            guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            onUpdate?(Self.parse(d))
        }
    }

    static func parse(_ d: [String: Any]) -> NowPlaying? {
        guard let pid = d["pid"] as? Int, pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid_t(pid))
        let num = { (k: String) in (d[k] as? NSNumber)?.doubleValue ?? 0 }
        return NowPlaying(player: nil, appName: app?.localizedName ?? "Now Playing", appIcon: app?.icon,
                          title: d["title"] as? String ?? "", artist: d["artist"] as? String ?? "",
                          album: d["album"] as? String ?? "", duration: num("duration"), position: num("elapsed"),
                          playing: (d["playing"] as? NSNumber)?.boolValue ?? false,
                          at: Date(timeIntervalSince1970: num("at")), artworkURL: "",
                          cover: (d["artwork"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:)))
    }
}

// MARK: - Tile

struct MusicTile: View {
    @ObservedObject var music = MusicController.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    private func on(_ part: String) -> Bool { settings.shows(.music, part) }

    var body: some View {
        Group {
            if let np = music.now {
                playing(np)
            } else if let p = music.runningPlayers.first(where: { music.access[$0] == .needsAsk }), !music.systemWorks {
                message("\(p.title) is open",
                        "Connect lets Notch Island read and control playback.",
                        button: "Connect") { music.connect(p) }
            } else if let p = music.runningPlayers.first(where: { music.access[$0] == .denied }), !music.systemWorks {
                message("Access to \(p.title) is off",
                        "Turn on Notch Island › \(p.appName) in Privacy & Security › Automation.",
                        button: "Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            } else {
                message("Nothing playing", "Play something in any app, such as Chrome, Safari, Spotify or Music.")
            }
        }
        .padding(12)
    }

    private func playing(_ np: NowPlaying) -> some View {
        let narrow = size.width < 200
        let short = size.height < 115
        let cover = min(size.height - 24, size.width * 0.35, 140)
        let textWidth = size.width - 24 - (narrow || !on("cover") ? 0 : cover + 12)
        let times = on("times") && textWidth >= 170 // elapsed + 3 buttons + total need ~170 pt
        // Narrow but tall: cover on top.
        let topCover = narrow && on("cover") && size.height >= 150
        return HStack(spacing: 12) {
            if !narrow, on("cover") { CoverView(image: np.cover, size: cover, corner: 10) }
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let pos = np.position(at: ctx.date)
                VStack(alignment: .leading, spacing: 3) {
                    if topCover { CoverView(image: np.cover, size: min(size.width - 24, size.height - 100), corner: 8) }
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(np.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                            Text(np.artist.isEmpty ? np.appName : np.artist).font(.system(size: 11)).foregroundStyle(theme.secondary)
                        }
                        Spacer(minLength: 0)
                        if on("appIcon"), !narrow, let icon = np.appIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16).help(np.appName) }
                    }
                    if !narrow, !short, on("lyrics") {
                        Text(music.currentLyric(at: pos) ?? " ")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.accent)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            .animation(.easeInOut(duration: 0.2), value: music.currentLyric(at: pos))
                    }
                    Spacer(minLength: 0)
                    if on("progress") {
                        ProgressBar(value: np.duration > 0 ? pos / np.duration : 0) { f in
                            if np.duration > 0 { music.seek(to: f * np.duration) }
                        }
                    }
                    HStack(spacing: 0) {
                        if times { Text(clock(pos)).font(.system(size: 9).monospacedDigit()).foregroundStyle(theme.secondary) }
                        Spacer()
                        if on("previous") { TileButton(symbol: "backward.fill") { music.previous() } }
                        TileButton(symbol: np.playing ? "pause.fill" : "play.fill") { music.playPause() }
                        TileButton(symbol: "forward.fill") { music.next() }
                        Spacer()
                        if times { Text(clock(np.duration)).font(.system(size: 9).monospacedDigit()).foregroundStyle(theme.secondary) }
                    }
                }
                .lineLimit(1)
            }
        }
    }

    private func message(_ title: String, _ detail: String, button: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TileHeader(symbol: "music.note", title: "NOW PLAYING")
            Spacer(minLength: 0)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1).minimumScaleFactor(0.8)
            Hint(detail)
            if let button, let action {
                Button(button, action: action).buttonStyle(FlatButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func clock(_ s: Double) -> String {
        let s = max(0, Int(s)); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Thin progress bar. With `onSeek`, clicking it jumps to that point (0...1).
struct ProgressBar: View {
    let value: Double
    var onSeek: ((Double) -> Void)? = nil
    @Environment(\.theme) var theme
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.secondary.opacity(0.25))
                Capsule().fill(theme.accent).frame(width: g.size.width * min(max(value, 0), 1))
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in onSeek?(min(max(p.x / g.size.width, 0), 1)) }
        }
        .frame(height: onSeek == nil ? 3 : 10)
    }
}

/// Flat, matte pill button (no glass, no gradient).
struct FlatButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.theme) var theme
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : theme.text)
            .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 3 : 5)
            .background(prominent ? theme.button : theme.secondary.opacity(0.18), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
