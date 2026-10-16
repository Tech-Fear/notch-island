import SwiftUI
import UniformTypeIdentifiers

/// Notch outline: flat top with small outward curves that melt into the menu bar, rounded bottom.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let b = min(bottom, r.height / 2, (r.width - 2 * ear) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + b, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - b), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandRootView: View {
    @ObservedObject var model = IslandModel.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        island
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var bottomRadius: CGFloat {
        switch model.state {
        case .resting: 9
        case .compact: 12
        case .peek: 20
        case .expanded: 26
        }
    }

    private var island: some View {
        let theme = settings.themeColors
        let shape = NotchShape(ear: NotchGeometry.ear, bottom: bottomRadius)
        let open = model.state == .peek || model.state == .expanded
        return content
            .frame(width: model.width(for: model.state), alignment: .top)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    theme.background
                    Color.black.frame(height: model.notch.height) // the real notch band stays black
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { model.islandSize = $0 })
            .compositingGroup()
            .shadow(color: .black.opacity(open ? 0.28 : 0), radius: 14, y: 6)
            .environment(\.theme, theme)
            .animation(IslandModel.spring, value: model.state)
            .animation(IslandModel.spring, value: settings.theme)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .resting:
            Color.clear.frame(height: model.notch.height)
        case .compact:
            CompactView(side: model.compactSide)
                .frame(height: model.notch.height)
                .padding(.horizontal, NotchGeometry.ear)
                .transition(.opacity)
        case .peek:
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notch.height)
                if let peek = model.peek { PeekView(peek: peek) }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
        case .expanded:
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notch.height)
                ExpandedView(width: model.width(for: .expanded) - 2 * NotchGeometry.ear)
                    .padding(.horizontal, NotchGeometry.ear)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

// MARK: - Theme environment

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.named(.darkMatte) }
private struct TileSizeKey: EnvironmentKey { static let defaultValue = CGSize(width: 300, height: 132) }
extension EnvironmentValues {
    /// Size of the tile being drawn, so a tile can switch to a narrow layout.
    var tileSize: CGSize {
        get { self[TileSizeKey.self] }
        set { self[TileSizeKey.self] = newValue }
    }
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Compact (black pill on both sides of the notch)

struct CompactView: View {
    let side: CGFloat
    @ObservedObject var model = IslandModel.shared
    @ObservedObject var claude = ClaudeBridge.shared
    @ObservedObject var music = MusicController.shared
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var sensors = SensorWatcher.shared
    @ObservedObject var tasks = TaskCenter.shared
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: side)
            Spacer(minLength: 0)
            right.frame(width: side)
                .overlay(alignment: .trailing) {
                    // Like iOS: green = camera, orange = microphone (both when both are on).
                    if sensors.active, model.activity != .sensor { sensorDots(size: 6).padding(.trailing, 4) }
                }
        }
    }

    @ViewBuilder private var left: some View {
        switch model.activity {
        case .claude:
            Image(systemName: claude.step.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .contentTransition(.symbolEffect(.replace))
        case .task:
            Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
        case .timer:
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
        case .music:
            CoverView(image: music.now?.cover, size: 20, corner: 5)
        case .sensor:
            HStack(spacing: 4) {
                if sensors.cameraOn { Image(systemName: "video.fill").foregroundStyle(Color.green) }
                if sensors.micApps != nil { Image(systemName: "mic.fill").foregroundStyle(Color.orange) }
            }
            .font(.system(size: 11, weight: .semibold))
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var right: some View {
        switch model.activity {
        case .claude:
            HStack(spacing: 4) { WorkingGrid(color: theme.accent); runningBadge }
        case .task:
            if let p = tasks.items.last?.progress {
                Text("\(Int(p * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.bandText)
            } else {
                HStack(spacing: 4) { WorkingGrid(color: theme.accent); runningBadge }
            }
        case .timer:
            Text(timer.remainingText).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.bandText)
        case .music: EqualizerBars(color: theme.accent)
        case .sensor:
            sensorDots(size: 7)
        case nil: EmptyView()
        }
    }
}

extension CompactView {
    /// "3" when several Claude sessions / commands are running at once.
    @ViewBuilder var runningBadge: some View {
        let n = claude.sessions.count + tasks.items.count
        if n > 1 {
            Text("\(n)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(Color.black)
                .padding(.horizontal, 4).background(theme.accent, in: Capsule())
        }
    }

    func sensorDots(size: CGFloat) -> some View {
        HStack(spacing: 3) {
            if sensors.cameraOn { Circle().fill(Color.green).frame(width: size, height: size) }
            if sensors.micApps != nil { Circle().fill(Color.orange).frame(width: size, height: size) }
        }
    }
}

/// Small 3x3 grid of dots that ripples while Claude works.
struct WorkingGrid: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
                ForEach(0..<3) { row in
                    GridRow {
                        ForEach(0..<3) { col in
                            let phase = sin(t * 5 - Double(row + col) * 0.8)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(color.opacity(0.35 + 0.65 * (phase + 1) / 2))
                                .frame(width: 3.5, height: 3.5)
                        }
                    }
                }
            }
        }
    }
}

struct EqualizerBars: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { i in
                    Capsule().fill(color)
                        .frame(width: 2.5, height: 4 + 9 * abs(sin(t * (3 + Double(i) * 0.7) + Double(i))))
                }
            }
            .frame(height: 14)
        }
    }
}

struct CoverView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat
    @Environment(\.theme) var theme
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    theme.tile
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(theme.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

// MARK: - Peek bubble

struct PeekView: View {
    let peek: Peek
    @Environment(\.theme) var theme
    var body: some View {
        HStack(spacing: 12) {
            switch peek.icon {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.accent)
                    .frame(width: 28, height: 28)
            case .image(let img):
                Image(nsImage: img).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                if let s = peek.subtitle {
                    Text(s).font(.system(size: 11)).foregroundStyle(theme.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    let width: CGFloat
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var model = IslandModel.shared
    @ObservedObject var claude = ClaudeBridge.shared
    @ObservedObject var tasks = TaskCenter.shared
    @Environment(\.theme) var theme

    private let pad: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let req = claude.visible {
                PermissionView(request: req, queued: claude.pending.count - 1)
            } else if let preview = model.preview {
                var l = settings.layout
                let _ = (l.tileHeight = preview.height)
                page(preview.tiles, layout: l)
            } else if model.dragNear {
                DropZone(height: CGFloat(settings.layout.tileHeight))
            } else {
                ActivityBar()
                carousel
            }
        }
        .padding(pad)
    }

    @ViewBuilder private var carousel: some View {
        let layout = settings.layout
        let index = min(model.page, max(layout.pages.count - 1, 0))
        if layout.pages.allSatisfy(\.isEmpty) {
            Text("No widgets. Add some with Edit Layout… in the menu bar.")
                .font(.system(size: 12)).foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            page(layout.pages[index], layout: layout)
                .id(index)
                .transition(.opacity.combined(with: .offset(x: 12)))
            if layout.pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(layout.pages.indices, id: \.self) { i in
                        Circle().fill(i == index ? theme.accent : theme.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                            .padding(3).contentShape(Rectangle())
                            .onTapGesture { model.showPage(i) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, -4)
            }
        }
    }

    @ViewBuilder private func page(_ tiles: [Placement], layout: IslandLayout) -> some View {
        let spacing = CGFloat(layout.spacing)
        let units = CGFloat(max(tiles.reduce(0) { $0 + $1.width }, 1))
        let unit = (width - 2 * pad - spacing * CGFloat(max(tiles.count - 1, 0))) / units
        if tiles.isEmpty {
            Text("This page is empty.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity, minHeight: CGFloat(layout.tileHeight))
        } else {
            HStack(spacing: spacing) {
                ForEach(tiles) { t in
                    let size = CGSize(width: unit * CGFloat(t.width), height: CGFloat(layout.tileHeight))
                    Self.tile(t.kind)
                        .environment(\.tileSize, size)
                        .frame(width: size.width, height: size.height, alignment: .top) // overflow goes down, never hides the header
                        .background(theme.tile, in: RoundedRectangle(cornerRadius: CGFloat(layout.corner)))
                        .clipShape(RoundedRectangle(cornerRadius: CGFloat(layout.corner)))
                }
            }
        }
    }

    @ViewBuilder static func tile(_ kind: TileKind) -> some View {
        switch kind {
        case .music: MusicTile()
        case .weather: WeatherTile()
        case .calendar: CalendarTile()
        case .timer: TimerTile()
        case .volume: VolumeTile()
        case .shelf: ShelfTile()
        case .clipboard: ClipboardTile()
        case .controls: ControlsTile()
        case .battery: BatteryTile()
        case .reminders: RemindersTile()
        case .stats: StatsTile()
        case .launcher: LauncherTile()
        case .countdown: CountdownTile()
        case .colorPicker: ColorPickerTile()
        case .notes: NotesTile()
        case .actions: ActionsTile()
        case .downloads: DownloadsTile()
        case .ports: PortsTile()
        case .git: GitTile()
        case .docker: DockerTile()
        }
    }
}

/// Shown while a file is dragged near the notch: drop anywhere on the island.
struct DropZone: View {
    let height: CGFloat
    @ObservedObject var shelf = Shelf.shared
    @Environment(\.theme) var theme
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 30)).foregroundStyle(theme.accent)
            Text("Drop files, images or text").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            Text("Files and images go to the Shelf, text to Quick Notes.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: max(height, 120))
        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
    }
}

/// Explanation text in a widget. Short widgets drop it (unless `always`) so the header and the
/// button still fit; when shown it wraps to at most 3 lines and shrinks a little before cutting.
struct Hint: View {
    let text: String
    var always = false
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    init(_ text: String, always: Bool = false) { self.text = text; self.always = always }

    var body: some View {
        if always || size.height >= 125 {
            Text(text).font(.system(size: 11)).foregroundStyle(theme.secondary)
                .lineLimit(size.height >= 125 ? 3 : 2).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Font size that follows the widget's height, within limits.
func scaled(_ size: CGSize, _ factor: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    min(max(size.height * factor, low), high)
}

/// Shared tile header: small icon + caption.
struct TileHeader: View {
    let symbol: String
    let title: String
    @Environment(\.theme) var theme
    var body: some View {
        // Icon + title when it fits, icon alone when it doesn't.
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
            Image(systemName: symbol)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.secondary)
    }
}

/// Flat button used inside tiles.
struct TileButton: View {
    let symbol: String
    var size: CGFloat = 13
    let action: () -> Void
    @Environment(\.theme) var theme
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
