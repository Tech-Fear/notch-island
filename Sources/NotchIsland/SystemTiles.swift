import AppKit
import AudioToolbox
import CoreAudio
import CoreMediaIO
import SwiftUI

// MARK: - CoreAudio helpers

func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
    var addr = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func setValue<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) {
    var addr = address(selector, scope)
    var v = value
    AudioObjectSetPropertyData(obj, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
}

func getArray<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type) -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var items = [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { _, n in n = Int(size) / MemoryLayout<T>.stride }
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &items) == noErr else { return [] }
    return items
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return "Output" }
    return ref.takeRetainedValue() as String
}

// MARK: - Volume + output device (public CoreAudio, no permission)

@MainActor
final class AudioOutput: ObservableObject {
    static let shared = AudioOutput()

    struct Device: Identifiable, Hashable { let id: AudioDeviceID; let name: String }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var current: AudioDeviceID = 0
    @Published private(set) var volume: Float? // nil: this output has no software volume (e.g. some HDMI)
    @Published private(set) var muted = false
    private var started = false
    private var watched: Set<AudioDeviceID> = []
    private var known: Set<AudioDeviceID>?

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let out = kAudioDevicePropertyScopeOutput
    private let mainVolume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    func start() {
        guard !started else { return }
        started = true
        listen(system, address(kAudioHardwarePropertyDefaultOutputDevice))
        listen(system, address(kAudioHardwarePropertyDevices))
        refresh()
    }

    private func listen(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) {
        var addr = addr
        AudioObjectAddPropertyListenerBlock(obj, &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        current = getValue(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)) ?? 0
        devices = getArray(system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
            .filter { !getArray($0, kAudioDevicePropertyStreams, out, of: AudioStreamID.self).isEmpty }
            .map { Device(id: $0, name: deviceName($0)) }
        let ids = Set(devices.map(\.id))
        if let known {
            for d in devices where !known.contains(d.id) {
                DeviceBattery.lookup(d.name) { battery in
                    IslandModel.shared.show(Peek(icon: .symbol("headphones"), title: "\(d.name) connected", subtitle: battery, duration: 4))
                }
            }
        }
        known = ids
        if current != 0, !watched.contains(current) {
            // shortcut: listeners on previously used outputs stay registered; they only trigger a refresh.
            watched.insert(current)
            listen(current, address(mainVolume, out))
            listen(current, address(kAudioDevicePropertyMute, out))
        }
        volume = getValue(current, mainVolume, out, Float32(0))
        muted = (getValue(current, kAudioDevicePropertyMute, out, UInt32(0)) ?? 0) != 0
    }

    var currentName: String { devices.first { $0.id == current }?.name ?? "Output" }

    func setVolume(_ v: Float) {
        setValue(current, mainVolume, out, Float32(min(max(v, 0), 1)))
        if muted, v > 0 { setValue(current, kAudioDevicePropertyMute, out, UInt32(0)) }
        refresh()
    }

    func toggleMute() {
        setValue(current, kAudioDevicePropertyMute, out, UInt32(muted ? 0 : 1))
        refresh()
    }

    func select(_ d: Device) {
        setValue(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, d.id)
        refresh()
    }
}

struct VolumeTile: View {
    @ObservedObject var audio = AudioOutput.shared
    @ObservedObject var vols = AppVolumes.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    private func on(_ part: String) -> Bool { settings.shows(.volume, part) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TileHeader(symbol: "speaker.wave.2", title: "VOLUME")
                Spacer(minLength: 4)
                // Output = whole Mac, Apps = each app on its own.
                HStack(spacing: 2) {
                    tab("Output", "speaker.wave.2.fill", !vols.showApps) { vols.showApps = false }
                    tab("Apps", "square.grid.2x2.fill", vols.showApps) { vols.showApps = true }
                }
            }
            if vols.showApps {
                AppVolumeList()
            } else {
            Spacer(minLength: 0)
            if let v = audio.volume {
                HStack(spacing: 8) {
                    if on("mute") {
                        TileButton(symbol: audio.muted || v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") { audio.toggleMute() }
                    }
                    FlatSlider(value: Double(audio.muted ? 0 : v)) { audio.setVolume(Float($0)) }
                    if on("percent"), size.width >= 150 { Text("\(Int((audio.muted ? 0 : v) * 100))").font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(theme.secondary).frame(width: 22, alignment: .trailing) }
                }
            } else {
                Text("This output has no volume control.").font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            if on("device"), size.height >= 100 { Menu {
                ForEach(audio.devices) { d in
                    Button { audio.select(d) } label: {
                        if d.id == audio.current { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            } label: {
                Label(audio.currentName, systemImage: "hifispeaker").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: size.width - 24, alignment: .leading)
            .foregroundStyle(theme.text) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tab(_ title: String, _ symbol: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group { if size.width >= 190 { Text(title) } else { Image(systemName: symbol) } }
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(selected ? Color.white : theme.secondary)
                .background(selected ? theme.button : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// Flat, matte slider: drag or click anywhere on the track.
struct FlatSlider: View {
    let value: Double
    let onChange: (Double) -> Void
    @Environment(\.theme) var theme
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.secondary.opacity(0.25)).frame(height: 6)
                Capsule().fill(theme.accent).frame(width: max(6, g.size.width * value), height: 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onChange(min(max($0.location.x / g.size.width, 0), 1)) })
        }
        .frame(height: 18)
    }
}

// MARK: - Microphone / camera in use (no permission: only asks *whether* they run, never reads them)

@MainActor
final class SensorWatcher: ObservableObject {
    static let shared = SensorWatcher()

    @Published private(set) var micApps: [String]? // nil: microphone not in use
    @Published private(set) var cameraOn = false
    private var timer: Timer?

    var active: Bool { micApps != nil || cameraOn }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        let mic = Self.micUsers()
        let cam = Self.cameraRunning()
        if mic != nil, micApps == nil {
            let names = mic!.isEmpty ? nil : mic!.joined(separator: ", ")
            IslandModel.shared.show(Peek(icon: .symbol("mic.fill"), title: "Microphone in use", subtitle: names))
        }
        if cam, !cameraOn {
            IslandModel.shared.show(Peek(icon: .symbol("video.fill"), title: "Camera in use", subtitle: nil))
        }
        if mic != micApps || cam != cameraOn {
            micApps = mic; cameraOn = cam
            IslandModel.shared.recompute()
        }
    }

    /// Apps recording from any input (per-app list on macOS 14+). [] = in use, app unknown.
    private static func micUsers() -> [String]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let processes = getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        if !processes.isEmpty {
            let names = processes.compactMap { p -> String? in
                guard getValue(p, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, UInt32(0)) == 1,
                      let pid = getValue(p, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0)),
                      pid != getpid() else { return nil }
                return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "An app"
            }
            return names.isEmpty ? nil : Array(Set(names)).sorted()
        }
        // Older systems: only "is the default input running".
        let input = getValue(system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)) ?? 0
        let running = getValue(input, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        return running != 0 ? [] : nil
    }

    private static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return false }
        addr.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { dev in
            var running: UInt32 = 0
            var got: UInt32 = 0
            return CMIOObjectGetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr && running != 0
        }
    }
}

// MARK: - File shelf (keeps references to files you drop on the notch; never copies them)

@MainActor
final class Shelf: ObservableObject {
    static let shared = Shelf()
    @Published private(set) var files: [URL] { didSet { UserDefaults.standard.set(files.map(\.path), forKey: "shelf") } }

    private init() {
        files = (UserDefaults.standard.stringArray(forKey: "shelf") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func add(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: NSURL.self) { obj, err in
                guard let url = obj as? URL, url.isFileURL else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if !self.files.contains(url) { self.files.append(url) } }
                }
            }
        }
    }

    func add(_ urls: [URL]) { for u in urls where !files.contains(u) { files.append(u) } }

    /// Dropped images are saved here (they have no file of their own).
    static let captures = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchIsland/Captures", isDirectory: true)

    func saveCapture(_ data: Data) -> URL? {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: Self.captures, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Self.captures.appendingPathComponent("Image \(f.string(from: Date())).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// The no-drag way in: a normal Open panel.
    func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add to Shelf"
        NSApp.activate(ignoringOtherApps: true)
        IslandModel.shared.holdOpen(true)
        panel.begin { r in
            IslandModel.shared.holdOpen(false)
            if r == .OK { self.add(panel.urls) }
        }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url }; deleteIfCapture(url) }
    func clear() { files.forEach(deleteIfCapture); files.removeAll() }

    /// Images dropped on the notch were saved by us; your own files are never touched.
    private func deleteIfCapture(_ url: URL) {
        if url.deletingLastPathComponent().standardizedFileURL == Self.captures.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct ShelfTile: View {
    @ObservedObject var shelf = Shelf.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TileHeader(symbol: "tray", title: shelf.files.isEmpty ? "SHELF" : "SHELF · \(shelf.files.count)")
                Spacer()
                Button { shelf.pick() } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(theme.secondary).help("Add files…")
                if !shelf.files.isEmpty {
                    Button { shelf.clear() } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary).help("Clear the Shelf")
                }
            }
            if shelf.files.isEmpty {
                Spacer(minLength: 0)
                Hint("Drag files to the top of the screen, or press +.", always: true)
                Spacer(minLength: 0)
            } else {
                // Vertical grid: a sideways two-finger swipe stays free to flip pages.
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                        ForEach(shelf.files, id: \.self) { url in item(url) }
                    }
                    .padding(.top, 2)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func item(_ url: URL) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
            if settings.shows(.shelf, "names"), size.height >= 100 {
                Text(url.lastPathComponent).font(.system(size: 9)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle).frame(width: 58)
            }
        }
        .allowsHitTesting(false)
        // Drag, double-click and right-click are handled by AppKit underneath (see FileDragSource).
        .background(FileDragSource(url: url, onRemove: { shelf.remove(url) }))
        .overlay(alignment: .topTrailing) {
            // Remove just this file (the file itself stays where it is).
            Button { shelf.remove(url) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.text, theme.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove from Shelf")
            .offset(x: 2, y: -4)
        }
        .padding(.top, 4)
        .help(url.path)
    }
}

/// AppKit drag source for a shelf file. SwiftUI's onDrag never starts a drag in this
/// non-activating panel; beginDraggingSession does, and writes the file URL the way Finder does,
/// so Finder copies the file and terminals (Terminal, iTerm2, IntelliJ…) paste its path.
struct FileDragSource: NSViewRepresentable {
    let url: URL
    var onRemove: (() -> Void)?

    func makeNSView(context: Context) -> SourceView { SourceView(url: url, onRemove: onRemove) }
    func updateNSView(_ view: SourceView, context: Context) { view.url = url; view.onRemove = onRemove }

    final class SourceView: NSView, NSDraggingSource, NSSharingServicePickerDelegate {
        var url: URL
        var onRemove: (() -> Void)?
        private var down: NSEvent?

        init(url: URL, onRemove: (() -> Void)?) {
            self.url = url
            self.onRemove = onRemove
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            down = event
            if event.clickCount == 2 { NSWorkspace.shared.open(url) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down else { return }
            self.down = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            MainActor.assumeIsolated { IslandModel.shared.holdOpen(true) } // don't close under the drag
            beginDraggingSession(with: [item], event: down, source: self)
        }

        /// The system share menu (AirDrop, Messages, Mail…), anchored to this file.
        private func share() {
            MainActor.assumeIsolated { IslandModel.shared.holdOpen(true) } // keep the anchor on screen
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = self
            picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        }

        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            MainActor.assumeIsolated { IslandModel.shared.holdOpen(false) }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let m = NSMenu()
            m.addItem(ClosureMenuItem(title: "Open") { [url] in NSWorkspace.shared.open(url) })
            m.addItem(ClosureMenuItem(title: "Show in Finder") { [url] in NSWorkspace.shared.activateFileViewerSelecting([url]) })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(title: "Share…") { [weak self] in self?.share() })
            if let airdrop = NSSharingService(named: .sendViaAirDrop), airdrop.canPerform(withItems: [url]) {
                m.addItem(ClosureMenuItem(title: "AirDrop…") { [url] in airdrop.perform(withItems: [url]) })
            }
            if let onRemove {
                m.addItem(.separator())
                m.addItem(ClosureMenuItem(title: "Remove from Shelf") { onRemove() })
            }
            return m
        }
    }
}


// MARK: - New screenshots → Shelf (opt-in)

@MainActor
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()
    private var timer: Timer?
    private var known: Set<String> = []

    /// Where macOS saves screenshots (Screenshot app › Options › Save to), Desktop by default.
    private var folder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func setEnabled(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        known = Set(names())  // only screenshots taken from now on
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    private func check() {
        for name in names() where !known.contains(name) {
            let url = folder.appendingPathComponent(name)
            // macOS tags screenshots with this attribute, whatever the language of the file name.
            guard getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 else {
                // The tag can arrive a moment after the file; give up on files older than 10 s.
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if Date().timeIntervalSince(created) > 10 { known.insert(name) }
                continue
            }
            known.insert(name)
            Shelf.shared.add([url])
            IslandModel.shared.show(Peek(icon: .symbol("camera.viewfinder"), title: "Screenshot added to Shelf",
                                         subtitle: name, duration: 2))
        }
    }
}
