import AppKit
import Combine
import SwiftUI

extension AppSettings {
    /// Moves a widget to `page`, before `target` (or to the end). Works across pages.
    func move(_ id: UUID, toPage page: Int, before target: UUID?) {
        guard id != target, let from = layout.pages.firstIndex(where: { $0.contains { $0.id == id } }),
              let item = layout.pages[from].first(where: { $0.id == id }) else { return }
        var l = layout
        l.pages[from].removeAll { $0.id == id }
        let at = target.flatMap { t in l.pages[page].firstIndex { $0.id == t } } ?? l.pages[page].count
        l.pages[page].insert(item, at: at)
        layout = l
    }
}

/// Which widget's options popover is open (no @State without Xcode's macro plugin).
@MainActor
final class EditorState: ObservableObject {
    static let shared = EditorState()
    @Published var optionsFor: UUID?
}

/// Layout editor: drag widgets between pages, set widths, add/remove pages, tune island sizes.
/// While it's open the island stays open, so every change shows up live.
struct LayoutEditorView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var model = IslandModel.shared
    @ObservedObject var editor = EditorState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Island") {
                VStack(spacing: 6) {
                    slider("Width", $settings.layout.islandWidth, 520...1000)
                    slider("Widget height", $settings.layout.tileHeight, 100...220)
                    slider("Corner radius", $settings.layout.corner, 4...24)
                    slider("Spacing", $settings.layout.spacing, 4...20)
                }
                .padding(6)
            }

            Text("Drag widgets to reorder them or move them to another page. W sets how many columns a widget spans, H how many rows: make one widget taller and shorter ones stack beside it. Add the same widget as often as you like. Click a page title to show it in the island.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(settings.layout.pages.indices, id: \.self) { i in pageRow(i) }
                }
                .padding(.trailing, 16) // room for the scroll bar, so it never covers the trash buttons
            }

            HStack {
                Button { settings.layout.pages.append([]); model.showPage(settings.layout.pages.count - 1) } label: {
                    Label("Add Page", systemImage: "plus")
                }
                Spacer()
                Button("Reset to Default…") { confirmReset() }
                // A menu-bar app has no main menu, so ⌘W and Esc need their own button.
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut("w", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                Button("") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction).hidden()
            }
        }
        .padding(16)
        .frame(width: 720, height: 640)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            // Whole numbers without step ticks (a step of 1 draws a tick per value).
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset the layout to the default?"
        alert.informativeText = "Your pages, widgets and sizes are replaced by the default layout."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { settings.layout = .standard; model.showPage(0) }
    }

    private func pageRow(_ i: Int) -> some View {
        let tiles = settings.layout.pages[i]
        let current = model.page == i
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { model.showPage(i) } label: {
                    Text("Page \(i + 1)").font(.headline).foregroundStyle(current ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                if current { Text("showing").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    ForEach(TileKind.allCases) { k in
                        Button { settings.layout.pages[i].append(.init(kind: k, width: k == .music ? 2 : 1)) } label: {
                            Label(k.title, systemImage: k.symbol)
                        }
                    }
                } label: { Label("Add Widget", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Button(role: .destructive) {
                    settings.layout.pages.remove(at: i)
                    model.showPage(min(model.page, settings.layout.pages.count - 1))
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(settings.layout.pages.count == 1)
                .help("Delete this page")
            }
            // The same grid as the island: widths share out the columns, heights stack rows.
            let grid = PageGrid(tiles)
            let spacing: CGFloat = 6, rowH: CGFloat = 66
            GeometryReader { g in
                let colW = (g.size.width - spacing * CGFloat(grid.columns - 1)) / CGFloat(grid.columns)
                ZStack(alignment: .topLeading) {
                    ForEach(tiles) { t in
                        let cell = grid.cells[t.id] ?? (0, 0)
                        chip(t, page: i)
                            .frame(width: colW * CGFloat(t.width) + spacing * CGFloat(t.width - 1),
                                   height: rowH * CGFloat(t.height) + spacing * CGFloat(t.height - 1))
                            .offset(x: CGFloat(cell.col) * (colW + spacing), y: CGFloat(cell.row) * (rowH + spacing))
                    }
                }
            }
            .frame(height: rowH * CGFloat(grid.rows) + spacing * CGFloat(grid.rows - 1))
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(current ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                        style: StrokeStyle(lineWidth: 1, dash: tiles.isEmpty ? [4] : [])))
            .overlay { if tiles.isEmpty { Text("Empty page: drop a widget here").font(.caption).foregroundStyle(.secondary) } }
            .dropDestination(for: String.self) { items, _ in
                for s in items { if let id = UUID(uuidString: s) { settings.move(id, toPage: i, before: nil) } }
                return true
            }
        }
    }

    private func chip(_ t: Placement, page: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Label(t.kind.title, systemImage: t.kind.symbol)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Button { editor.optionsFor = t.id } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Options")
                    .popover(isPresented: Binding(get: { editor.optionsFor == t.id },
                                                  set: { if !$0 { editor.optionsFor = nil } })) { options(t.kind) }
                Button { settings.layout.pages[page].removeAll { $0.id == t.id } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove")
            }
            .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { resize(t, page: page, \.width, by: -1, IslandLayout.widthRange) } label: { Image(systemName: "minus") }
                    .disabled(t.width <= IslandLayout.widthRange.lowerBound)
                Text("W \(t.width)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Button { resize(t, page: page, \.width, by: 1, IslandLayout.widthRange) } label: { Image(systemName: "plus") }
                    .disabled(t.width >= IslandLayout.widthRange.upperBound)
                Spacer(minLength: 2)
                Button { resize(t, page: page, \.height, by: -1, IslandLayout.heightRange) } label: { Image(systemName: "minus") }
                    .disabled(t.height <= IslandLayout.heightRange.lowerBound)
                Text("H \(t.height)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Button { resize(t, page: page, \.height, by: 1, IslandLayout.heightRange) } label: { Image(systemName: "plus") }
                    .disabled(t.height >= IslandLayout.heightRange.upperBound)
            }
            .buttonStyle(.borderless)
            .help("W: columns wide · H: rows tall (shorter widgets stack beside taller ones)")
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
        .draggable(t.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            for s in items { if let id = UUID(uuidString: s) { settings.move(id, toPage: page, before: t.id) } }
            return true
        }
    }

    /// Switches for the parts of one widget type (shared by every copy of that widget).
    private func options(_ kind: TileKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(kind.title, systemImage: kind.symbol).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(kind.parts) { part in
                        Toggle(part.title, isOn: Binding(get: { settings.shows(kind, part.id) },
                                                         set: { settings.setPart(kind, part.id, $0) }))
                    }
                }
            }
            .frame(maxHeight: 320)
            Text("Parts also hide on their own when the widget is too small.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func resize(_ t: Placement, page: Int, _ side: WritableKeyPath<Placement, Int>, by delta: Int, _ range: ClosedRange<Int>) {
        guard let j = settings.layout.pages[page].firstIndex(where: { $0.id == t.id }) else { return }
        let v = settings.layout.pages[page][j][keyPath: side] + delta
        if range.contains(v) { settings.layout.pages[page][j][keyPath: side] = v }
    }
}

@MainActor
final class LayoutEditorController: NSObject, NSWindowDelegate {
    static let shared = LayoutEditorController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LayoutEditorView()))
            w.title = "Edit Layout"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        // A menu-bar app may not be allowed to come forward; orderFrontRegardless shows the window anyway.
        window?.orderFrontRegardless()
        window?.makeKey()
        IslandModel.shared.setEditing(window?.isVisible == true)
        // Never leave the island held open by an editor that isn't on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.window?.isVisible != true { IslandModel.shared.setEditing(false) }
        }
        // The open island sits at the top of the screen: keep the editor below it, also when it grows.
        sizeWatch = IslandModel.shared.$islandSize
            .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
            .sink { [weak self] size in MainActor.assumeIsolated { self?.placeBelowIsland(size) } }
    }

    private var sizeWatch: AnyCancellable?

    private func placeBelowIsland(_ island: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let islandBottom = IslandModel.shared.notch.screenFrame.maxY - island.height - 30 - 10 // 30: the panel's shadow margin
        let top = min(window.frame.maxY, islandBottom)
        guard window.frame.maxY > islandBottom || window.frame.minY < screen.visibleFrame.minY else { return }
        let y = max(screen.visibleFrame.minY, top - window.frame.height)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: y))
    }

    func windowWillClose(_ notification: Notification) {
        sizeWatch = nil
        IslandModel.shared.setEditing(false)
    }
}
