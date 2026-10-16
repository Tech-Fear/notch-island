import AppKit

/// Saves a PNG of each visible window of this app (no screen-recording permission needed: it only
/// draws its own views). Used to check the UI during development: send
/// {"hook_event_name":"NotchIslandSnapshot"} to the socket; files go to $TMPDIR/NotchIsland-snapshots.
@MainActor
enum Snapshots {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("NotchIsland-snapshots") }

    /// Optional setup before the picture: {"page": 1, "options": "timer", "dropZone": true}.
    static func prepare(_ e: [String: Any]) {
        if let page = e["page"] as? Int { IslandModel.shared.showPage(page) }
        if let kind = (e["options"] as? String).flatMap(TileKind.init(rawValue:)) {
            EditorState.shared.optionsFor = AppSettings.shared.layout.pages.flatMap { $0 }.first { $0.kind == kind }?.id
        }
        if let drop = e["dropZone"] as? Bool { IslandModel.shared.setDragNear(drop) }
        if let apps = e["volumeApps"] as? Bool { AppVolumes.shared.showApps = apps }
        // {"viewer": {"mode": "Compare", "a": "…", "b": "…"}}: fill the viewer for a picture.
        if let v = e["viewer"] as? [String: String], let mode = ViewerMode(rawValue: v["mode"] ?? "") {
            ViewerWindow.shared.open(mode: mode, text: v["a"] ?? "", focus: false)
            ViewerModel.shared.inputB = v["b"] ?? ""
        }
        if let editor = e["editor"] as? Bool { // the Edit Layout window, for a picture
            if editor { LayoutEditorController.shared.show() } else { NSApp.windows.first { $0.title == "Edit Layout" }?.close() }
        }
        if e["closeViewer"] as? Bool == true { NSApp.windows.first { $0 is ViewerPanel }?.close() }
        if let open = e["open"] as? Bool { IslandModel.shared.setEditing(open) } // hold the island open for a picture
        // "preview": "controls:2,battery:1:2" (kind:width:height), "height": 132 ; "preview": "" ends it.
        if let spec = e["preview"] as? String {
            let tiles = spec.split(separator: ",").compactMap { part -> Placement? in
                let kv = part.split(separator: ":")
                guard let kind = TileKind(rawValue: String(kv[0])) else { return nil }
                return Placement(kind: kind, width: kv.count > 1 ? Int(kv[1]) ?? 1 : 1, height: kv.count > 2 ? Int(kv[2]) ?? 1 : 1)
            }
            IslandModel.shared.preview = tiles.isEmpty ? nil : (tiles, e["height"] as? Double ?? 132)
        }
    }

    static func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pb = NSPasteboard.general
        var state = "pasteboard changeCount=\(pb.changeCount) types=\((pb.types ?? []).map(\.rawValue)) "
        if #available(macOS 15.4, *) { state += "accessBehavior=\(pb.accessBehavior.rawValue) " }
        state += "appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none") "
        state += "screens=\(NSScreen.screens.map { "\($0.localizedName) \($0.frame) top=\($0.safeAreaInsets.top)" }) notch=\(IslandModel.shared.notch.screenFrame) "
        state += "viewerInput=\(String(reflecting: ViewerModel.shared.input)) "
        let c = ClaudeBridge.shared
        state += "claudeSessions=\(c.sessions.count) step=\(c.step.verb) detail=\(c.detail) pending=\(c.pending.count) tasks=\(TaskCenter.shared.items.count) "
        // Can this app open each Shelf file? (errno 1 = macOS privacy settings say no.)
        let access = Shelf.shared.files.map { f -> String in
            let fd = open(f.path, O_RDONLY)
            defer { if fd >= 0 { close(fd) } }
            return "\(f.lastPathComponent):" + (fd >= 0 ? "ok" : "errno \(errno)")
        }
        state += "shelfAccess=\(access) "
        state += "clipboardItems=\(ClipboardHistory.shared.items.count) enabled=\(ClipboardHistory.shared.enabled)\n"
        try? state.write(to: folder.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
        for (i, w) in NSApp.windows.enumerated() where w.isVisible {
            guard let view = w.contentView?.superview ?? w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = (w.title.isEmpty ? String(describing: type(of: w)) : w.title).replacingOccurrences(of: " ", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(i)-\(name).png"))
        }
    }
}
