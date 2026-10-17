import AppKit
import Combine
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var island: IslandManager!
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

    /// A screen with the island hanging from its top edge. A template image, so macOS tints it for light
    /// and dark menu bars like its own icons.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 17, height: 13), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.4
            screen.stroke()
            // The island: flat against the top edge, rounded below.
            let island = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 8.6, width: 9, height: 5), xRadius: 2.5, yRadius: 2.5)
            island.append(NSBezierPath(rect: NSRect(x: 5.5, y: 11.6, width: 9, height: 2.9)))
            island.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch Island"
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { DragHandoff.removeAll() } // drag links left by a quit or crash
        NSApp.mainMenu = Self.makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        island = IslandManager()
        Hotkeys.shared.checkAvailability()
        ClaudeBridge.shared.start()
        PeekCenter.shared.start()
        WeatherService.shared.start()
        SensorWatcher.shared.start()
        NetworkWatcher.shared.start()
        ClipboardHistory.shared.start()
        ScreenshotWatcher.shared.setEnabled(AppSettings.shared.screenshotsToShelf)
        // First launch (e.g. from the .dmg): there's no Dock icon, so say where things are.
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                IslandModel.shared.show(Peek(icon: .symbol("capsule.fill"), title: "Notch Island is running",
                                             subtitle: "Hover the notch · settings in the menu bar", duration: 4))
            }
        }
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

    /// otpauth:// links clicked anywhere open the Authenticator's add window, filled in.
    func application(_ application: NSApplication, open urls: [URL]) {
        let links = urls.filter { $0.scheme == "otpauth" }.map(\.absoluteString)
        if !links.isEmpty { OTPAddWindow.shared.show(text: links.joined(separator: "\n")) }
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
        // Grouped by what they're for, so the menu stays short.
        for group in TileKind.Group.allCases {
            let tiles = TileKind.allCases.filter { $0.group == group }
            let on = tiles.filter(s.layout.contains).count
            menu.addItem(submenu("\(group.rawValue)  (\(on)/\(tiles.count))", symbol: group.symbol, tiles.map { tile in
                item(tile.title, on: s.layout.contains(tile)) { s.toggle(tile) }
            }))
        }
        menu.addItem(item("Edit Layout…") { LayoutEditorController.shared.show() })
        menu.addItem(item("Dev Toolbox…") { ViewerWindow.shared.open(mode: .json, text: nil) })
        menu.addItem(item("Weather City: " + (s.city.isEmpty ? "not set" : s.city) + "…") { SettingsWindowController.shared.show() })
        if s.layout.contains(.music) {
            menu.addItem(info(MusicController.shared.systemWorks ? "   Now Playing: any app"
                                                                  : "   Now Playing: waiting for playback"))
        }

        menu.addItem(.separator())
        menu.addItem(submenu("Theme", symbol: "paintpalette", ThemeName.allCases.map { t in item(t.title, on: s.theme == t) { s.theme = t } }))
        // With more than one display: where the island goes.
        var screenItems = IslandScreens.allCases.map { m in item(m.title, on: s.islandScreens == m) { s.islandScreens = m } }
        if s.islandScreens == .chosen {
            screenItems.append(.separator())
            screenItems.append(item("Automatic (notch screen, else main)", on: s.islandScreenName == nil) { s.islandScreenName = nil })
            for name in NSScreen.screens.map(\.localizedName) {
                screenItems.append(item(name, on: s.islandScreenName == name) { s.islandScreenName = name })
            }
        }
        menu.addItem(submenu("Screens", symbol: "display.2", screenItems))
        let peeks = PeekCenter.shared
        var peekItems = [item("Focus / Do Not Disturb", on: s.focusPeeks) { peeks.setFocusPeeks(!s.focusPeeks) }]
        if s.focusPeeks, let note = peeks.focusNote { peekItems.append(info("   " + note)) }
        peekItems += [
            item("Load Spotify Covers (contacts Spotify)", on: s.spotifyCovers) { s.spotifyCovers.toggle() },
            item("New Screenshots → Shelf", on: s.screenshotsToShelf) {
                s.screenshotsToShelf.toggle()
                ScreenshotWatcher.shared.setEnabled(s.screenshotsToShelf)
            },
        ]
        menu.addItem(submenu("Peeks", symbol: "bubble.left", peekItems))
        menu.addItem(submenu("Claude Code", symbol: "terminal", [
            info(ClaudeBridge.shared.listening ? "Listening for hooks" : "Socket unavailable"),
            info(Hotkeys.shared.conflict ?? "Allow ⌃⌥Y · Deny ⌃⌥N"),
            .separator(),
            item("Copy Hook Settings JSON") { Self.copyHookSettings() },
            item("Install “notch” Command", on: Self.cliInstalled) { Self.installCLI() },
        ]))

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", on: s.launchAtLogin) {
            do { try s.setLaunchAtLogin(!s.launchAtLogin) } catch { Self.alert("Couldn't change Launch at Login", error.localizedDescription) }
        })
        menu.addItem(item("Settings…") { SettingsWindowController.shared.show() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func submenu(_ title: String, symbol: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
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

    /// A menu-bar app shows no menu bar, but ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z / ⌘W only work through menu items:
    /// without this hidden Edit menu they do nothing in the viewer, notes and settings windows.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Quit Notch Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag =
            Int(NSFindPanelAction.showFindPanel.rawValue)
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(); windowItem.submenu = window; main.addItem(windowItem)
        return main
    }

    /// ~/.local/bin/notch → the helper inside this app, for scripts (`notch run -- …`). No Terminal needed.
    static var cliLink: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/notch") }
    static var cliInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) == hookPath
    }

    @MainActor static func installCLI() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: cliLink.path)) != nil || fm.fileExists(atPath: cliLink.path) {
                try fm.removeItem(at: cliLink)
            }
            try fm.createSymbolicLink(atPath: cliLink.path, withDestinationPath: hookPath)
            IslandModel.shared.show(Peek(icon: .symbol("terminal"), title: "“notch” installed",
                                         subtitle: "~/.local/bin/notch (add ~/.local/bin to your PATH)", duration: 4))
        } catch {
            alert("Couldn't install the notch command", error.localizedDescription)
        }
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
