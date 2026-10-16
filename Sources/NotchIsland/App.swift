import AppKit
import Combine
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var island: IslandController!
    private var bag = Set<AnyCancellable>()

    static func main() {
        // Used by `install.sh uninstall`: remove the login item, which only the app itself can do.
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        signal(SIGPIPE, SIG_IGN) // a dead Now Playing helper must not kill the app
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        island = IslandController()
        Hotkeys.shared.checkAvailability()
        ClaudeBridge.shared.start()
        PeekCenter.shared.start()
        WeatherService.shared.start()
        SensorWatcher.shared.start()
        NetworkWatcher.shared.start()
        ClipboardHistory.shared.start()
        ScreenshotWatcher.shared.setEnabled(AppSettings.shared.screenshotsToShelf)
        AudioOutput.shared.start() // also announces headphones/speakers when they connect

        // Now Playing and volume watch the system only while their widget is on some page.
        let layout = AppSettings.shared.$layout
        layout.map { $0.contains(.music) }.removeDuplicates().sink { on in
            if on { MusicController.shared.start() } else { MusicController.shared.stop() }
        }.store(in: &bag)
        for (kind, poller) in [(TileKind.ports, PortsWatcher.shared as Poller), (.git, GitWatcher.shared), (.docker, DockerWatcher.shared)] {
            layout.map { $0.contains(kind) }.removeDuplicates().sink { on in
                if on { poller.start() } else { poller.stop() }
            }.store(in: &bag)
        }
        layout.map { $0.contains(.stats) }.removeDuplicates().sink { on in
            if on { SystemStats.shared.start() } else { SystemStats.shared.stop() }
        }.store(in: &bag)
        layout.map { $0.contains(.volume) }.removeDuplicates().sink { on in
            if on { AppVolumes.shared.start() } else { AppVolumes.shared.stop() }
        }.store(in: &bag)
        layout.map { $0.contains(.weather) }.removeDuplicates().dropFirst().sink { on in
            if on { WeatherService.shared.refresh() }
        }.store(in: &bag)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppVolumes.shared.stop() // give every tapped app its own sound back
        ClaudeBridge.shared.stop()
    }

    // MARK: Menu (rebuilt each time it opens, so it's always current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = AppSettings.shared
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(info("Notch Island \(version)"))
        menu.addItem(.separator())

        menu.addItem(header("Widgets"))
        for tile in TileKind.allCases {
            menu.addItem(item(tile.title, on: s.layout.contains(tile)) { s.toggle(tile) })
        }
        menu.addItem(item("Edit Layout…") { LayoutEditorController.shared.show() })
        menu.addItem(item("Weather City: " + (s.city.isEmpty ? "not set" : s.city) + "…") { SettingsWindowController.shared.show() })
        if s.layout.contains(.music) {
            menu.addItem(info(MusicController.shared.systemWorks ? "   Now Playing: any app"
                                                                  : "   Now Playing: waiting for playback"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Theme"))
        for t in ThemeName.allCases {
            menu.addItem(item(t.title, on: s.theme == t) { s.theme = t })
        }

        menu.addItem(.separator())
        menu.addItem(header("Peeks"))
        let peeks = PeekCenter.shared
        menu.addItem(item("Focus / Do Not Disturb", on: s.focusPeeks) { peeks.setFocusPeeks(!s.focusPeeks) })
        if s.focusPeeks, let note = peeks.focusNote { menu.addItem(info("   " + note)) }
        menu.addItem(item("Load Spotify Covers (contacts Spotify)", on: s.spotifyCovers) { s.spotifyCovers.toggle() })
        menu.addItem(item("New Screenshots → Shelf", on: s.screenshotsToShelf) {
            s.screenshotsToShelf.toggle()
            ScreenshotWatcher.shared.setEnabled(s.screenshotsToShelf)
        })

        menu.addItem(.separator())
        menu.addItem(header("Claude Code"))
        menu.addItem(info(ClaudeBridge.shared.listening ? "   Listening for hooks" : "   Socket unavailable"))
        menu.addItem(info("   " + (Hotkeys.shared.conflict ?? "Allow ⌃⌥Y · Deny ⌃⌥N")))
        menu.addItem(item("Copy Hook Settings JSON") { Self.copyHookSettings() })

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", on: s.launchAtLogin) {
            do { try s.setLaunchAtLogin(!s.launchAtLogin) } catch { Self.alert("Couldn't change Launch at Login", error.localizedDescription) }
        })
        menu.addItem(item("Settings…") { SettingsWindowController.shared.show() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return info(title)
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, on: Bool? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: action)
        if let on { i.state = on ? .on : .off }
        return i
    }

    static var hookPath: String { Bundle.main.bundlePath + "/Contents/MacOS/notch-hook" }

    /// The lines for ~/.claude/settings.json. Copied to the clipboard; you paste them yourself.
    static var hookSettingsJSON: String {
        let cmd = "\"\(hookPath)\""
        func entry(_ matcher: String?, timeout: Int? = nil) -> [String: Any] {
            var h: [String: Any] = ["type": "command", "command": cmd]
            if let timeout { h["timeout"] = timeout }
            var e: [String: Any] = ["hooks": [h]]
            if let matcher { e["matcher"] = matcher }
            return e
        }
        let hooks: [String: Any] = [
            "UserPromptSubmit": [entry(nil)],
            "PreToolUse": [entry("*")],
            "PermissionRequest": [entry("*", timeout: 150)],
            "Notification": [entry(nil)],
            "Stop": [entry(nil)],
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["hooks": hooks],
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!
    }

    @MainActor static func copyHookSettings() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hookSettingsJSON, forType: .string)
        IslandModel.shared.show(Peek(icon: .symbol("doc.on.clipboard"), title: "Hook settings copied",
                                     subtitle: "Merge them into ~/.claude/settings.json"))
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
