import AppKit
import Combine
import SwiftUI

// MARK: - Notch geometry

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var width: CGFloat      // width of the hardware notch (or the fake one)
    var height: CGFloat     // height of the notch / menu bar band
    var hasNotch: Bool
    var screenID: CGDirectDisplayID = 0

    static let ear: CGFloat = 6 // outward curve where the island meets the menu bar

    /// One screen's notch; screens without one get a drawn notch at the top centre.
    static func of(_ s: NSScreen) -> NotchGeometry {
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NotchGeometry(screenFrame: s.frame, width: s.frame.width - l.width - r.width,
                                 height: s.safeAreaInsets.top, hasNotch: true, screenID: s.displayID)
        }
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        return NotchGeometry(screenFrame: s.frame, width: 190, height: menuBar > 0 ? menuBar : 24, hasNotch: false, screenID: s.displayID)
    }

    /// The screen with the notch, else the main screen.
    static var defaultScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func detect() -> NotchGeometry { of(defaultScreen) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    static func under(_ p: NSPoint) -> NSScreen? { screens.first { NSMouseInRect(p, $0.frame, false) } }
}

/// Which screen one island is on (it moves when it follows the mouse).
@MainActor
final class IslandPlace: ObservableObject {
    @Published var notch: NotchGeometry
    init(_ notch: NotchGeometry) { self.notch = notch }
    var screen: CGDirectDisplayID { notch.screenID }
}

// MARK: - Island state

enum IslandState { case resting, compact, peek, expanded }
enum CompactActivity { case claude, task, timer, music, sensor }

struct Peek: Identifiable {
    enum Icon { case symbol(String), image(NSImage) }
    let id = UUID()
    var icon: Icon
    var title: String
    var subtitle: String?
    var duration: TimeInterval = 3   // 2 to 4 seconds
}

@MainActor
final class IslandModel: ObservableObject {
    static let shared = IslandModel()

    @Published private(set) var state: IslandState = .resting
    @Published private(set) var activity: CompactActivity?
    @Published private(set) var peek: Peek?
    @Published var notch = NotchGeometry.detect()
    @Published var islandSize: CGSize = .zero
    /// The screen whose island opens (hovered or used last). With an island on every screen, the others keep
    /// showing the status (resting / compact), except while Claude asks: a question opens on all of them.
    @Published var activeScreen: CGDirectDisplayID = 0
    @Published private(set) var askingEverywhere = false
    private var hoveredScreens: Set<CGDirectDisplayID> = []
    /// Carousel page shown when the island is open.
    @Published var page = 0
    /// Development preview (snapshot command): these widgets at this height, instead of the carousel.
    @Published var preview: (tiles: [Placement], height: Double)? { didSet { recompute() } }

    private var hoverExpanded = false
    private var editing = false   // the layout editor keeps the island open
    private var dropOpen = false  // files are being dragged over the island
    /// A file drag is in progress near the top of the screen: the island opens as a big drop zone.
    @Published private(set) var dragNear = false
    private var held = false      // a file is being dragged out of the shelf
    private var hoverTimer: Timer?
    private var peekQueue: [(Peek, Date)] = []
    private var peekTimer: Timer?

    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)

    // Hover: opens 0.15 s after the pointer reaches the notch area, closes when it leaves.
    func mouseInside(_ inside: Bool) {
        if inside {
            Awake.hold("hover", true)
            guard !hoverExpanded, hoverTimer == nil else { return } // don't restart a running countdown
            let t = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hoverTimer = nil
                    self?.hoverExpanded = true
                    self?.recompute()
                }
            }
            t.tolerance = 0
            RunLoop.main.add(t, forMode: .common)
            hoverTimer = t
        } else {
            cancelHoverTimer()
            Awake.hold("hover", false)
            if hoverExpanded {
                hoverExpanded = false
                recompute()
            }
        }
    }

    private func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// Hover from one island: the island counts as hovered while the pointer is on any of them.
    func mouseInside(_ inside: Bool, screen: CGDirectDisplayID) {
        if inside {
            hoveredScreens.insert(screen)
            if activeScreen != screen { activeScreen = screen }
        } else {
            hoveredScreens.remove(screen)
        }
        mouseInside(!hoveredScreens.isEmpty)
    }

    /// What the island on `screen` shows: the shared state, but only the active screen's island opens.
    func state(on screen: CGDirectDisplayID, _ s: IslandState? = nil) -> IslandState {
        let s = s ?? state
        guard s == .expanded, screen != activeScreen, !askingEverywhere else { return s }
        return activity != nil ? .compact : .resting
    }

    // A click opens it right away (no wait). It still closes as soon as the pointer leaves.
    func clickedInside() {
        cancelHoverTimer()
        hoverExpanded = true
        recompute()
    }

    /// Close now, e.g. after answering Claude, even though the pointer may still be on the island.
    func dismiss() {
        cancelHoverTimer()
        hoverExpanded = false
        recompute()
    }

    func showPage(_ i: Int) {
        let count = AppSettings.shared.layout.pages.count
        guard count > 0 else { return }
        withAnimation(Self.spring) { page = min(max(i, 0), count - 1) }
    }

    func setEditing(_ on: Bool) { editing = on; recompute() }
    func holdOpen(_ on: Bool) {
        guard held != on else { return }
        held = on
        recompute()
        // SwiftUI's onDrag has no "drag ended" callback, so watch the mouse button instead.
        if on {
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    if NSEvent.pressedMouseButtons & 1 == 0 { t.invalidate(); self?.holdOpen(false) }
                }
            }
        }
    }

    /// Dragging files over the island opens it on the page with the shelf.
    func setDropTargeted(_ on: Bool) {
        guard dropOpen != on else { return }
        dropOpen = on
        if on, let i = AppSettings.shared.layout.page(of: .shelf) { showPage(i) }
        recompute()
    }

    func setDragNear(_ on: Bool) {
        guard dragNear != on else { return }
        dragNear = on
        if on, let i = AppSettings.shared.layout.page(of: .shelf) { showPage(i) }
        recompute()
        // Other apps' drags swallow the mouse-up, so watch the button to know when the drag ended.
        if on {
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.dragNear else { t.invalidate(); return }
                    if NSEvent.pressedMouseButtons & 1 == 0 {
                        t.invalidate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.setDragNear(false) } // let the drop land first
                    }
                }
            }
        }
    }

    func show(_ peek: Peek) {
        peekQueue.append((peek, Date()))
        pumpPeeks()
    }

    private func pumpPeeks() {
        guard peek == nil, state != .expanded else { return }
        peekQueue.removeAll { Date().timeIntervalSince($0.1) > 8 } // stale bubbles are dropped
        guard !peekQueue.isEmpty else { return }
        let next = peekQueue.removeFirst().0
        peek = next
        recompute()
        peekTimer = Timer.scheduledTimer(withTimeInterval: next.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.peek = nil
                self?.recompute()
                self?.pumpPeeks()
            }
        }
    }

    /// Called whenever anything that affects the island changes.
    func recompute() {
        let claude = ClaudeBridge.shared
        if askingEverywhere != !claude.pending.isEmpty { askingEverywhere = !claude.pending.isEmpty }
        if claude.working { activity = .claude }
        else if !TaskCenter.shared.items.isEmpty { activity = .task }
        else if FocusTimer.shared.running { activity = .timer }
        else if MusicController.shared.now?.playing == true { activity = .music }
        else if SensorWatcher.shared.active { activity = .sensor }
        else { activity = nil }

        let new: IslandState
        if hoverExpanded || editing || preview != nil || dropOpen || dragNear || held || !claude.pending.isEmpty { new = .expanded }
        else if peek != nil { new = .peek }
        else if activity != nil { new = .compact }
        else { new = .resting }

        if new != state {
            // Bubbles and the open island run short timers; keep them on time (see Awake).
            if new == .peek || new == .expanded {
                Awake.hold("island", true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in // after the 0.5 s shrink
                    if let s = self?.state, s != .peek, s != .expanded { Awake.hold("island", false) }
                }
            }
            withAnimation(Self.spring) { state = new }
            if new != .expanded { pumpPeeks() }
        }
    }

    // Island widths per state (heights come from the content).
    var compactSide: CGFloat { 58 }
    var restingWidth: CGFloat { notch.width + 2 * NotchGeometry.ear }
    /// `on`: the screen's notch (each screen's island has its own); the active one by default.
    func width(for s: IslandState, on n: NotchGeometry? = nil) -> CGFloat {
        let resting = (n ?? notch).width + 2 * NotchGeometry.ear
        switch s {
        case .resting: return resting
        case .compact: return resting + 2 * compactSide
        case .peek: return max(resting + 2 * compactSide, 360)
        case .expanded: return AppSettings.shared.layout.islandWidth
        }
    }

    /// The panel is sized to hold the largest island of the current state, plus room for the shadow.
    func panelSize(for s: IslandState, on n: NotchGeometry? = nil) -> CGSize {
        let g = n ?? notch, margin: CGFloat = 40
        switch s {
        case .resting, .compact: return CGSize(width: width(for: .compact, on: g) + margin, height: g.height + margin)
        case .peek: return CGSize(width: width(for: .peek, on: g) + margin, height: g.height + 120)
        case .expanded: return CGSize(width: width(for: .expanded, on: g) + margin,
                                      height: min(g.screenFrame.height * 0.8, 640))
        }
    }
}

// MARK: - App Nap

/// macOS throttles the timers of an idle background app ("App Nap"), so a 0.25 s hover timer or a
/// 3 s bubble could fire seconds late. App Nap is turned off only while something timed is on screen.
@MainActor
enum Awake {
    private static var held: [String: NSObjectProtocol] = [:]

    static func hold(_ reason: String, _ on: Bool) {
        if on, held[reason] == nil {
            held[reason] = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: reason)
        } else if !on, let a = held.removeValue(forKey: reason) {
            ProcessInfo.processInfo.endActivity(a)
        }
    }
}

// MARK: - Panel

/// Borderless, transparent, non-activating: it never takes focus from the app you're using.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the soft shadow is drawn by SwiftUI so it follows the island's shape
        isFloatingPanel = true // must come before `level`: it resets the level to .floating
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    /// macOS skips windows that can't become key when it looks for a drop target, so key status is
    /// allowed only while a file is being dragged. Even then the panel never needs the keyboard
    /// (becomesKeyOnlyIfNeeded), so it doesn't take focus from your app.
    var acceptsDrops = false
    override var canBecomeKey: Bool { acceptsDrops }
    override var canBecomeMain: Bool { false }

    /// AppKit normally pushes windows below the menu bar; the island has to sit on top of the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Clicks work on the first try, even though the panel is never the key window.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Let file drags fall through to IslandContainerView, which handles them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { superview?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { superview?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { superview?.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { superview?.performDragOperation(sender) ?? false }
}

/// What can be dropped on the island: files (Shelf), an image (saved, then Shelf) or text (a Quick Note).
enum Dropped {
    case files([URL]), image(Data), text(String)

    init?(_ pb: NSPasteboard) {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            self = .files(urls)
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            self = .image(data)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .text(s)
        } else {
            return nil
        }
    }
}

/// Owns the tracking area. It covers only the visible island, so hovering the menu bar does nothing.
final class IslandContainerView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    var islandSize: CGSize = .zero { didSet { if islandSize != oldValue { updateTrackingAreas(); checkMouse() } } }

    /// Extra hover margin around the small resting/compact island: the bare notch is a tiny
    /// target and real hovers often brush past it in under 0.25 s.
    var slack: CGFloat = 0 { didSet { if slack != oldValue { updateTrackingAreas(); checkMouse() } } }

    /// Wide to the sides (the menu bar beside the notch is how the pointer usually arrives, so the countdown
    /// starts on the way in), shallow below it (the browser tab bar sits right under the notch).
    var hoverRect: NSRect {
        let below = min(slack, 14)
        return NSRect(x: (bounds.width - islandSize.width) / 2 - slack, y: bounds.height - islandSize.height - below,
                      width: islandSize.width + 2 * slack, height: islandSize.height + below + 2) // +2: the very top pixel row counts
    }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
        super.updateTrackingAreas()
        DispatchQueue.main.async { [weak self] in self?.checkMouse() }
    }

    // Enter/exit are only hints: AppKit also sends them when the area is rebuilt (window resize, page
    // change) while the mouse hasn't moved, so the real position decides.
    // MARK: File drops (AppKit: SwiftUI's onDrop doesn't receive drags in this panel)

    var onDropped: ((Dropped) -> Void)?
    var onDropHover: ((Bool) -> Void)?

    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .string]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Dropped(sender.draggingPasteboard) != nil else { return [] }
        onDropHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Dropped(sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDropHover?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropHover?(false)
        guard let dropped = Dropped(sender.draggingPasteboard) else { return false }
        onDropped?(dropped)
        return true
    }

    override func mouseEntered(with event: NSEvent) { checkMouse() }
    override func mouseExited(with event: NSEvent) { checkMouse() }

    /// After the area changes size, AppKit doesn't send enter/exit for a mouse that's already there.
    func checkMouse() {
        guard let window else { return }
        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        onHover?(hoverRect.contains(p))
    }
}

/// One island window. `target` says which screen it belongs on (asked again at every move).
@MainActor
final class IslandController {
    private let panel = IslandPanel()
    private let container = IslandContainerView()
    private let model = IslandModel.shared
    private var bag = Set<AnyCancellable>()
    private var shrinkWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var positionTimer: Timer?
    private let target: () -> NSScreen
    let place: IslandPlace
    private var islandSize: CGSize = .zero

    /// The state this island shows (only the active screen's island opens).
    private var shown: IslandState { model.state(on: place.screen) }

    init(target: @escaping () -> NSScreen) {
        self.target = target
        place = IslandPlace(NotchGeometry.of(target()))
        let host = FirstMouseHostingView(rootView: IslandRootView(place: place, onSize: { [weak self] in self?.sized($0) }))
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.onHover = { [weak self] inside in
            guard let self else { return }
            self.model.mouseInside(inside, screen: self.place.screen)
        }
        container.registerForDraggedTypes(IslandContainerView.dropTypes)
        container.onDropHover = { [weak self] on in self?.model.setDropTargeted(on) }
        container.onDropped = { dropped in
            switch dropped {
            case .files(let urls):
                Shelf.shared.add(urls)
                IslandModel.shared.show(Peek(icon: .symbol("tray.and.arrow.down.fill"), title: "Added to Shelf",
                                             subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files", duration: 2))
            case .image(let data):
                guard let url = Shelf.shared.saveCapture(data) else { return }
                Shelf.shared.add([url])
                IslandModel.shared.show(Peek(icon: .symbol("photo"), title: "Image added to Shelf", subtitle: url.lastPathComponent, duration: 2))
            case .text(let text):
                Notes.shared.upsert(Note(text: text))
                IslandModel.shared.show(Peek(icon: .symbol("note.text"), title: "Saved to Notes",
                                             subtitle: String(text.prefix(40)), duration: 2))
            }
        }
        panel.contentView = container

        model.$dragNear.sink { [weak self] on in self?.panel.acceptsDrops = on }.store(in: &bag)
        // In step with the change (not a tick later), so the opening animation is never clipped.
        model.$state.sink { [weak self] s in
            guard let self else { return }
            self.apply(self.model.state(on: self.place.screen, s))
        }.store(in: &bag)
        // Another screen's island opened, or a question for every island: re-check once the change is in.
        model.$activeScreen.map { _ in () }.merge(with: model.$askingEverywhere.map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { if let self { self.apply(self.shown) } } }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                for delay in [0.0, 1.0, 3.0] { // and again once the change has settled
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self?.resize(for: self?.model.state ?? .resting, immediately: true)
                    }
                }
            }.store(in: &bag)

        // A click on the notch opens the island at once. (Mouse monitors need no permission.)
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            if e.window === self?.panel, let self {
                let p = self.container.convert(e.locationInWindow, from: nil)
                if self.container.hoverRect.contains(p) {
                    self.model.activeScreen = self.place.screen
                    self.model.clickedInside()
                }
            }
            return e
        }) { monitors.append(m) }

        // File drags: the drag pasteboard changes when a drag starts. Once a file drag comes near
        // the notch, open the island as a drop zone, so there's no waiting and no small target.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.trackFileDrag(e) }
        }) { monitors.append(m) }

        // Two-finger horizontal swipe on the open island flips carousel pages.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            self?.swipe(e)
            return e
        }) { monitors.append(m) }

        AppSettings.shared.$layout.dropFirst().sink { [weak self] layout in
            guard let self else { return }
            if self.model.page >= layout.pages.count { self.model.showPage(layout.pages.count - 1) }
            if self.shown == .expanded { self.resize(for: .expanded, immediately: true) }
        }.store(in: &bag)

        // Display changes (lid closed with a monitor, a monitor unplugged during sleep) don't always
        // notify, and the island once stayed off-screen. Re-check its position every few seconds.
        positionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target = self.frame(for: self.shown)
                if abs(self.panel.frame.midX - target.midX) > 1 || abs(self.panel.frame.maxY - target.maxY) > 1 {
                    self.resize(for: self.shown, immediately: true)
                }
            }
        }

        apply(shown, immediately: true)
        panel.orderFrontRegardless()
    }

    private func apply(_ s: IslandState, immediately: Bool = false) {
        container.slack = (s == .resting || s == .compact) ? 40 : 0
        resize(for: s, immediately: immediately)
    }

    /// Moves the island to `target`'s screen now (the screen changed).
    func relocate() { resize(for: shown, immediately: true) }

    /// Takes the island down (the screen setting changed or its display is gone).
    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        bag.removeAll()
        positionTimer?.invalidate()
        shrinkWork?.cancel()
        fitWork?.cancel()
        panel.orderOut(nil)
    }

    private func sized(_ size: CGSize) {
        islandSize = size
        container.islandSize = size
        if place.screen == model.activeScreen { model.islandSize = size } // the editor and viewer place themselves by it
        fitExpanded(to: size)
    }

    private var dragCount = NSPasteboard(name: .drag).changeCount

    private func trackFileDrag(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            dragCount = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != dragCount,
                  pb.types?.contains(where: IslandContainerView.dropTypes.contains) == true else { return }
            let p = NSEvent.mouseLocation, screen = place.notch.screenFrame
            // Generous zone: top 180 pt of the screen, 760 pt wide around the notch.
            let near = p.y > screen.maxY - 180 && abs(p.x - screen.midX) < 380
            if near {
                if model.activeScreen != place.screen { model.activeScreen = place.screen } // the drop zone opens here
                model.setDragNear(true)
            }
            else if model.dragNear, !panel.frame.contains(p) { model.setDragNear(false) }
        default: // mouse up: the drop (if any) has been handled by then
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.model.setDragNear(false) }
        }
    }

    private var swipeX: CGFloat = 0
    private var swiped = false

    private func swipe(_ e: NSEvent) {
        guard e.window === panel, shown == .expanded, ClaudeBridge.shared.pending.isEmpty else { return }
        // A trackpad gesture starts with .began; a mouse wheel sends phase-less events, each its own "gesture".
        if e.phase == .began || (e.phase.isEmpty && e.momentumPhase.isEmpty) { swipeX = 0; swiped = false }
        guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        swipeX += e.scrollingDeltaX
        if !swiped, abs(swipeX) > 40 {
            swiped = true // one page per gesture
            model.showPage(model.page + (swipeX < 0 ? 1 : -1))
        }
    }

    private func frame(for s: IslandState) -> NSRect {
        // Screens can be half-updated right after a display change: re-check every time.
        let notch = NotchGeometry.of(target())
        if notch != place.notch { place.notch = notch }
        if place.screen == model.activeScreen, notch != model.notch { model.notch = notch }
        let size = model.panelSize(for: s, on: notch)
        let screen = notch.screenFrame
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private var fitWork: DispatchWorkItem?

    /// The open island's panel starts at its maximum height so the opening animation is never clipped,
    /// then shrinks to the island once it settles, so no invisible window area covers other windows.
    private func fitExpanded(to size: CGSize) {
        fitWork?.cancel()
        guard shown == .expanded, size.height > 0 else { return }
        let full = frame(for: .expanded)
        if size.height + 30 > panel.frame.height { panel.setFrame(full, display: true); return } // content grew
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shown == .expanded else { return }
            var f = full
            f.size.height = min(full.height, self.islandSize.height + 30) // room for the shadow
            f.origin.y = full.maxY - f.height
            if abs(f.height - self.panel.frame.height) > 1 { self.panel.setFrame(f, display: true) }
        }
        fitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Grow right away; shrink only after the closing animation has finished.
    private func resize(for s: IslandState, immediately: Bool = false) {
        shrinkWork?.cancel()
        fitWork?.cancel()
        let target = frame(for: s)
        if immediately || target.height >= panel.frame.height || target.width >= panel.frame.width {
            panel.setFrame(target, display: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.shown == s else { return }
                self.panel.setFrame(target, display: true)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }
}


// MARK: - Islands on more than one screen

/// One island per screen, one that follows the pointer, or one on a chosen screen (Settings › Screens).
/// They all show the same status from IslandModel.
@MainActor
final class IslandManager {
    private var islands: [IslandController] = []
    private var bag = Set<AnyCancellable>()
    private var followTimer: Timer?
    private var followScreen = NotchGeometry.defaultScreen
    private var screenIDs: [CGDirectDisplayID] = []

    init() {
        let settings = AppSettings.shared
        settings.$islandScreens.map { _ in () }.merge(with: settings.$islandScreenName.map { _ in () }).dropFirst(2)
            .sink { [weak self] in DispatchQueue.main.async { self?.rebuild() } }.store(in: &bag)
        // Displays plugged in or out: an island for each new one (all) or back on the chosen screen.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, NSScreen.screens.map(\.displayID) != self.screenIDs else { return }
                self.rebuild()
            }.store(in: &bag)
        rebuild()
    }

    static var chosenScreen: NSScreen {
        if let name = AppSettings.shared.islandScreenName, let s = NSScreen.screens.first(where: { $0.localizedName == name }) { return s }
        return NotchGeometry.defaultScreen
    }

    private func rebuild() {
        islands.forEach { $0.close() }
        followTimer?.invalidate()
        followTimer = nil
        screenIDs = NSScreen.screens.map(\.displayID)
        let model = IslandModel.shared
        switch AppSettings.shared.islandScreens {
        case .all:
            model.activeScreen = NotchGeometry.defaultScreen.displayID
            islands = NSScreen.screens.map { screen in
                let id = screen.displayID
                return IslandController { NSScreen.screens.first { $0.displayID == id } ?? NotchGeometry.defaultScreen }
            }
        case .chosen:
            model.activeScreen = Self.chosenScreen.displayID
            islands = [IslandController { Self.chosenScreen }]
        case .followMouse:
            followScreen = NSScreen.under(NSEvent.mouseLocation) ?? NotchGeometry.defaultScreen
            model.activeScreen = followScreen.displayID
            islands = [IslandController { [weak self] in self?.followScreen ?? NotchGeometry.defaultScreen }]
            // Checking where the pointer is costs next to nothing; the island moves only while it's closed.
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        model.notch = NotchGeometry.of(NSScreen.screens.first { $0.displayID == model.activeScreen } ?? NotchGeometry.defaultScreen)
    }

    private func follow() {
        let model = IslandModel.shared
        guard model.state != .expanded, !model.dragNear,
              let screen = NSScreen.under(NSEvent.mouseLocation), screen.displayID != followScreen.displayID else { return }
        followScreen = screen
        model.activeScreen = screen.displayID
        islands.first?.relocate()
    }
}
