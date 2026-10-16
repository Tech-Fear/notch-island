import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

// MARK: - Per-app volume (Core Audio process taps)
//
// macOS has no per-app volume. For an app you turn down, a process tap captures its audio and
// mutes the original; a private aggregate device plays the captured audio to your output at the
// chosen level. At 100% the tap is removed and the app plays untouched. Needs the
// "System Audio Recording" permission; the audio never leaves the Mac.

/// Copies the tap's channels (the last `tapChannels` input channels) to every output channel,
/// scaled by `gain`. Handles interleaved and non-interleaved Float32 buffers. Real-time safe.
func mixTapped(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
               gain: Float, tapChannels: Int = 2) {
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outs = UnsafeMutableAudioBufferListPointer(output)
    for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    var inChannels = 0
    for b in ins { inChannels += Int(b.mNumberChannels) }
    guard inChannels > 0 else { return }
    // An aggregate lists the output device's own inputs (a headset mic) before the tap's channels.
    let base = max(0, inChannels - tapChannels)
    let tapCount = inChannels - base
    var outIndex = 0
    for ob in outs {
        let oc = Int(ob.mNumberChannels)
        defer { outIndex += oc }
        guard oc > 0, let od = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let outFrames = Int(ob.mDataByteSize) / MemoryLayout<Float>.size / oc
        for k in 0..<oc {
            let src = base + min(outIndex + k, tapCount - 1)
            var first = 0
            for ib in ins {
                let ic = Int(ib.mNumberChannels)
                if src < first + ic, ic > 0, let id = ib.mData?.assumingMemoryBound(to: Float.self) {
                    let ch = src - first
                    let frames = min(outFrames, Int(ib.mDataByteSize) / MemoryLayout<Float>.size / ic)
                    for f in 0..<frames { od[f * oc + k] = id[f * ic + ch] * gain }
                    break
                }
                first += ic
            }
        }
    }
}

private func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
    return ref.takeRetainedValue() as String
}

/// "System Audio Recording" permission. There's no public way to read it, so this uses the TCC
/// calls System Settings itself uses; if they're missing, it reports .unknown and the safety net
/// below still protects the app's sound.
enum AudioCapturePermission {
    enum Status { case granted, denied, notAsked, unknown } // unknown: this macOS doesn't offer the check
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    static var status: Status {
        guard let s = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        typealias Fn = @convention(c) (CFString, CFDictionary?) -> Int32
        switch unsafeBitCast(s, to: Fn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notAsked
        }
    }

    /// Shows the macOS prompt (only if not answered before).
    static func request(_ done: @escaping @Sendable (Bool) -> Void) {
        guard let s = dlsym(tcc, "TCCAccessRequest") else { done(false); return }
        typealias Fn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        unsafeBitCast(s, to: Fn.self)(service, nil, done)
    }
}

/// One app that makes sound, with all its audio processes (Chrome plays from helper processes).
struct AudioApp: Identifiable, Equatable {
    let id: String          // the app's bundle identifier
    let name: String
    let icon: NSImage?
    let processes: [AudioObjectID]
    let playing: Bool

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.processes == b.processes && a.playing == b.playing
    }
}

/// Maps a helper's bundle id ("com.google.Chrome.helper.Renderer") to its app ("com.google.Chrome").
func owningAppBundleID(of bundleID: String, among apps: [String]) -> String? {
    if apps.contains(bundleID) { return bundleID }
    return apps.filter { bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count }
}

/// One running tap + aggregate device for one app.
final class AppTap {
    let processes: [AudioObjectID]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Shared with the real-time thread.
    let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init?(processes: [AudioObjectID], gain value: Float, outputUID: String) {
        self.processes = processes
        gain.pointee = value
        peak.pointee = 0
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { release(); return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Island per-app volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { release(); return nil }

        let gain = self.gain, peak = self.peak
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if let b = ins.last, let d = b.mData?.assumingMemoryBound(to: Float.self) {
                var p: Float = 0
                for i in 0..<Int(b.mDataByteSize) / MemoryLayout<Float>.size { p = max(p, abs(d[i])) }
                peak.pointee = max(peak.pointee, p)
            }
            mixTapped(input: input, output: output, gain: gain.pointee)
        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else { release(); return nil }
    }

    /// Stops playback and removes the tap, so the app plays normally again.
    func release() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit {
        release()
        gain.deallocate()
        peak.deallocate()
    }
}

@MainActor
final class AppVolumes: ObservableObject {
    static let shared = AppVolumes()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var gains: [String: Float] = UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Float] ?? [:]
    /// An app we turned down but whose captured audio stays silent: permission likely not granted.
    @Published private(set) var silentApp: String?
    @Published var showApps = false
    /// Turned-down apps play at full volume until the permission is granted (nothing is muted before).
    @Published private(set) var permission = AudioCapturePermission.status
    /// Apps whose tap stayed silent: tap removed so their own sound came back. Cleared when you move the slider.
    private var failed: Set<String> = []

    private var taps: [String: AppTap] = [:]
    private var timer: Timer?
    private var silentChecks: [String: Int] = [:]
    private var outputUID: String?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        taps.values.forEach { $0.release() }
        taps.removeAll()
    }

    func gain(_ app: AudioApp) -> Float { gains[app.id] ?? 1 }

    func setGain(_ app: AudioApp, _ value: Float) {
        let v = min(max(value, 0), 1)
        gains[app.id] = v >= 0.995 ? nil : v
        UserDefaults.standard.set(gains, forKey: "appVolumes")
        failed.remove(app.id)
        if v < 0.995, permission != .granted { requestPermission() }
        if let tap = taps[app.id] { tap.gain.pointee = v }
        refresh()
    }

    func toggleMute(_ app: AudioApp) { setGain(app, gain(app) > 0 ? 0 : 1) }

    func requestPermission() {
        permission = AudioCapturePermission.status
        guard permission != .granted else { return }
        if permission == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            return
        }
        AudioCapturePermission.request { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.permission = AudioCapturePermission.status
                self.refresh()
            } }
        }
    }

    /// The default output changed: rebuild every tap on the new device.
    func outputChanged() {
        taps.values.forEach { $0.release() }
        taps.removeAll()
        refresh()
    }

    private var scanning = false

    /// The audio-process scan can stall when coreaudiod is busy: it runs off the main thread, the rest here.
    private func refresh() {
        guard !scanning else { return }
        scanning = true
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let ids = running.compactMap(\.bundleIdentifier)
        DispatchQueue.global(qos: .utility).async {
            let (uid, groups) = Self.scan(ids)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.scanning = false; self.apply(uid: uid, groups: groups, running: running) }
            }
        }
    }

    /// The output device and the audio processes, grouped by the regular app that owns them.
    nonisolated private static func scan(_ ids: [String]) -> (String?, [String: (processes: [AudioObjectID], playing: Bool)]) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output = getValue(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)) ?? 0
        var groups: [String: (processes: [AudioObjectID], playing: Bool)] = [:]
        for p in getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
            guard let pid = getValue(p, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0)), pid != getpid(),
                  let bundle = stringProperty(p, kAudioProcessPropertyBundleID),
                  let owner = owningAppBundleID(of: bundle, among: ids) else { continue }
            let playing = getValue(p, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, UInt32(0)) == 1
            groups[owner, default: ([], false)].processes.append(p)
            if playing { groups[owner]!.playing = true }
        }
        return (stringProperty(output, kAudioDevicePropertyDeviceUID), groups)
    }

    private func apply(uid: String?, groups: [String: (processes: [AudioObjectID], playing: Bool)], running: [NSRunningApplication]) {
        if uid != outputUID { outputUID = uid; taps.values.forEach { $0.release() }; taps.removeAll() }
        let list = groups.compactMap { id, g -> AudioApp? in
            guard g.playing || gains[id] != nil, let app = running.first(where: { $0.bundleIdentifier == id }) else { return nil }
            return AudioApp(id: id, name: app.localizedName ?? id, icon: app.icon, processes: g.processes.sorted(), playing: g.playing)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if list != apps { apps = list }

        // Taps only for apps below 100%, and only once recording is allowed: a tap mutes the app's
        // own sound, so without permission it would go silent. Rebuilt when its processes change.
        let s = AudioCapturePermission.status
        if s != permission { permission = s }
        for app in list {
            let g = gain(app)
            if g >= 0.995 || failed.contains(app.id) || s == .denied || s == .notAsked { taps.removeValue(forKey: app.id)?.release(); continue }
            if let tap = taps[app.id], tap.processes == app.processes { continue }
            taps.removeValue(forKey: app.id)?.release()
            if let uid {
                taps[app.id] = AppTap(processes: app.processes, gain: g, outputUID: uid)
            }
        }
        for id in taps.keys where !list.contains(where: { $0.id == id }) { taps.removeValue(forKey: id)?.release() }

        // A tapped app that plays but yields only silence for ~6 s: permission is probably off.
        var silent: String?
        for app in list where app.playing && gain(app) > 0 {
            guard let tap = taps[app.id] else { continue }
            silentChecks[app.id] = tap.peak.pointee == 0 ? (silentChecks[app.id] ?? 0) + 1 : 0
            tap.peak.pointee = 0
            if (silentChecks[app.id] ?? 0) >= 3 {
                // Safety net: give the app its own sound back instead of leaving it silent.
                silent = app.name
                failed.insert(app.id)
                taps.removeValue(forKey: app.id)?.release()
                silentChecks[app.id] = 0
            }
        }
        if silent == nil, let shown = silentApp, list.contains(where: { $0.name == shown && failed.contains($0.id) }) { silent = shown }
        if silent != silentApp { silentApp = silent }
    }
}

/// The "Apps" side of the Volume widget.
struct AppVolumeList: View {
    @ObservedObject var vols = AppVolumes.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        if vols.apps.isEmpty {
            Text("No app is playing sound.").font(.system(size: 11)).foregroundStyle(theme.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if vols.permission != .granted, vols.apps.contains(where: { vols.gain($0) < 0.995 }) {
                    Button { vols.requestPermission() } label: {
                        Label("Allow System Audio Recording to change app volumes", systemImage: "lock")
                            .font(.system(size: 10)).foregroundStyle(theme.accent).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Until then, apps keep playing at full volume.")
                }
                if let name = vols.silentApp {
                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    } label: {
                        Label("\(name) restored to 100%: no audio received", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10)).foregroundStyle(theme.accent).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(vols.apps) { app in row(app) }
                    }
                }
            }
        }
    }

    private func row(_ app: AudioApp) -> some View {
        let g = vols.gain(app)
        return HStack(spacing: 6) {
            Button { vols.toggleMute(app) } label: {
                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16).opacity(g == 0 ? 0.4 : 1) }
            }
            .buttonStyle(.plain).help(g == 0 ? "Unmute \(app.name)" : "Mute \(app.name)")
            if size.width >= 220 {
                Text(app.name).font(.system(size: 10)).foregroundStyle(theme.text).lineLimit(1).frame(width: 64, alignment: .leading)
            }
            FlatSlider(value: Double(g)) { vols.setGain(app, Float($0)) }
            Text("\(Int(g * 100))").font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.secondary)
                .frame(width: 22, alignment: .trailing)
        }
        .help(app.name)
    }
}
