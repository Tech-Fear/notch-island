import AppKit
import Intents
import IOKit.ps

/// Watches the system and shows small bubbles under the notch.
@MainActor
final class PeekCenter: ObservableObject {
    static let shared = PeekCenter()

    @Published private(set) var focusStatus: INFocusStatusAuthorizationStatus = INFocusStatusCenter.default.authorizationStatus
    @Published private(set) var focusNote: String?

    private var onAC: Bool?
    private var warned: Set<Int> = []
    private var lastFocused: Bool?
    private var focusTimer: Timer?
    private var powerSource: CFRunLoopSource?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { self.app(n, launched: true) }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { self.app(n, launched: false) }
        }
        startPower()
        if AppSettings.shared.focusPeeks { startFocus() }
    }

    // MARK: Apps

    private func app(_ n: Notification, launched: Bool) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular, app != .current else { return }
        let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "/")
        IslandModel.shared.show(Peek(icon: .image(icon), title: app.localizedName ?? "App",
                                     subtitle: launched ? "Opened" : "Quit", duration: 2))
    }

    // MARK: Power (IOKit, no permission needed)

    private func startPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PeekCenter>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.powerChanged() }
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        powerChanged()
    }

    private func powerChanged() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let level = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let ac = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if let was = onAC, !was, ac {
                IslandModel.shared.show(Peek(icon: .symbol("battery.100percent.bolt"), title: "Charging", subtitle: "\(level)%"))
            }
            if ac { warned.removeAll() }
            else if onAC != nil {
                for threshold in [10, 20] where level <= threshold && !warned.contains(threshold) {
                    warned.formUnion([10, 20].filter { $0 >= threshold }) // never show 20% after 10%
                    IslandModel.shared.show(Peek(icon: .symbol(threshold == 10 ? "battery.0percent" : "battery.25percent"),
                                                 title: "Battery at \(level)%",
                                                 subtitle: threshold == 10 ? "Plug in soon" : "Low battery", duration: 4))
                    break
                }
            } else {
                // First reading after launch: don't warn about a level we were already at.
                warned.formUnion([10, 20].filter { level <= $0 })
            }
            onAC = ac
        }
    }

    // MARK: Focus / Do Not Disturb
    // There is no public Do Not Disturb API. INFocusStatusCenter says whether *a* Focus is on,
    // and only after you allow it. It can't tell Do Not Disturb apart from other Focus modes.

    func setFocusPeeks(_ on: Bool) {
        AppSettings.shared.focusPeeks = on
        if on {
            INFocusStatusCenter.default.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.focusStatus = status
                    self.startFocus()
                }
            }
        } else {
            focusTimer?.invalidate(); focusTimer = nil; lastFocused = nil
        }
    }

    private func startFocus() {
        focusStatus = INFocusStatusCenter.default.authorizationStatus
        guard focusStatus == .authorized else {
            focusNote = focusStatus == .notDetermined ? nil : "Focus access not granted"
            return
        }
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFocus() }
        }
        pollFocus()
    }

    private func pollFocus() {
        guard let focused = INFocusStatusCenter.default.focusStatus.isFocused else {
            focusNote = "macOS isn't sharing Focus status with this build"
            return
        }
        focusNote = nil
        if let last = lastFocused, last != focused {
            IslandModel.shared.show(Peek(icon: .symbol(focused ? "moon.fill" : "moon"),
                                         title: focused ? "Focus on" : "Focus off",
                                         subtitle: focused ? "Do Not Disturb or another Focus" : nil))
        }
        lastFocused = focused
    }
}
