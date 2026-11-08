import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var transfer: TransferController
    @State private var dragStartRatio: Double?

    init(state: AppState) {
        self.state = state
        self.transfer = state.transfer
    }

    var body: some View {
        let ui = state.ui
        VStack(spacing: 0) {
            WorkspaceToolbar(state: state)
            LayoutBar(state: state)
            panes(ui)
            CommandLineBar(state: state)
            FunctionKeyBar(state: state)
        }
        .background(ui.window)
        .overlay(alignment: .bottomTrailing) { JobBoxes(jobs: state.jobs) }
        .environment(\.ui, ui)
        .background(WindowSetup(state: state))
        // Questions go on the main window, or on top of whatever dialog is open.
        .sheet(item: Binding(get: { state.sheet == nil ? state.prompt : nil },
                             set: { if $0 == nil && state.sheet == nil && state.prompt != nil { state.finishPrompt(nil) } })) { request in
            PromptSheet(request: request, finish: { state.finishPrompt($0) }).environment(\.ui, ui)
        }
        .background(EmptyView().sheet(item: $state.sheet) { request in
            request.view
                .sheet(item: Binding(get: { state.prompt }, set: { if $0 == nil && state.prompt != nil { state.finishPrompt(nil) } })) { prompt in
                    PromptSheet(request: prompt, finish: { state.finishPrompt($0) }).environment(\.ui, ui)
                }
        })
        .background(EmptyView().sheet(item: $transfer.conflict) { request in
            ConflictSheet(request: request) { transfer.resolve($0, applyToAll: $1) }.environment(\.ui, ui)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Some folders cannot be watched; coming back to the window catches them up.
            state.catchUpQuietly()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.saveNow()
        }
    }

    private func panes(_ ui: UI) -> some View {
        GeometryReader { geometry in
            let strip = CenterStrip.width(ui)
            let available = max(0, geometry.size.width - strip)
            let ratio = min(max(state.settings.splitRatio, 0.15), 0.85)
            let leftWidth = (available * ratio).rounded()
            // The strip's buttons line up with the first row of the lists.
            let top = 3 + ui.s(30) + 3 + ui.s(25) + ui.s(22)

            HStack(spacing: 0) {
                PaneView(pane: state.left, state: state).frame(width: leftWidth)
                CenterStrip(state: state, topOffset: top)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("panes"))
                        .onChanged { value in
                            guard available > 0 else { return }
                            state.settings.splitRatio = min(max((value.location.x - strip / 2) / available, 0.15), 0.85)
                            state.objectWillChange.send()
                        }
                        .onEnded { _ in state.scheduleSave() })
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                PaneView(pane: state.right, state: state).frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "panes")
        }
        .padding(3)
    }
}

/// Reaches the hosting window once, to give it a size and position that persist.
struct WindowSetup: NSViewRepresentable {
    let state: AppState

    final class Hook: NSView {
        var onWindow: (NSWindow) -> Void = { _ in }
        private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            DispatchQueue.main.async { self.onWindow(window) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Hook()
        view.onWindow = { window in
            window.setFrameAutosaveName("MACCommanderMain")
            window.title = "MAC Commander — \(state.active.currentPath)"
            window.tabbingMode = .disallowed
            state.active.focusRequest += 1
            WindowSetup.watchThumbButtons(window, state: state)
            WindowSetup.snapshotIfAsked(window)
        }
        return view
    }

    /// The mouse's thumb buttons: back goes up a level, forward goes into the highlighted
    /// folder. They act on the pane being pointed at, making it active, and fall back to
    /// the active pane when the pointer is anywhere else. Handled for the whole window, so
    /// the two panes cannot both fire.
    static func watchThumbButtons(_ window: NSWindow, state: AppState) {
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak window, weak state] event in
            guard let window, let state, event.window === window,
                  event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
            let point = event.locationInWindow
            var side = state.activeSide
            if let content = window.contentView {
                // The pane whose column the pointer is in: left of the centre strip is left.
                let tables = allTables(in: content).compactMap { $0.enclosingScrollView }
                    .map { $0.convert($0.bounds, to: nil) }
                if tables.count == 2 {
                    let sorted = tables.sorted { $0.minX < $1.minX }
                    if point.x <= sorted[0].maxX + 2 { side = .left } else if point.x >= sorted[1].minX - 2 { side = .right }
                } else if let only = tables.first, only.minX - 2 ... only.maxX + 2 ~= point.x {
                    side = point.x < window.frame.width / 2 ? .left : .right
                }
            }
            let pane = state.pane(side)
            state.setActive(side)
            if event.buttonNumber == 3 { pane.goUp() } else { pane.enterHighlightedDirectory() }
            pane.focusRequest += 1
            return nil
        }
    }

    private static func allTables(in view: NSView) -> [FileTable] {
        var found: [FileTable] = []
        if let table = view as? FileTable { found.append(table) }
        for sub in view.subviews { found += allTables(in: sub) }
        return found
    }

    /// For checking the layout without a screen: `open --env MACC_SNAPSHOT=/tmp/x.png`
    /// makes the app draw its own window into that file a few seconds after it starts,
    /// and again whenever `/tmp/x.png.request` appears.
    static func snapshotIfAsked(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["MACC_SNAPSHOT"] else { return }
        func shoot() {
            guard let view = window.contentView?.superview ?? window.contentView else { return }
            // The window server's own picture of this window: SwiftUI's layers do not draw
            // through cacheDisplay or layer rendering. An app may always capture itself.
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") {
                let capture = unsafeBitCast(symbol, to: Capture.self)
                // optionIncludingWindow = 8, imageBoundsIgnoreFraming = 1
                if let image = capture(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }

            var dump = "window \(window.frame) first responder \(String(describing: window.firstResponder))\n"
            func walk(_ v: NSView, _ depth: Int) {
                guard depth < 14 else { return }
                var line = String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame.integral)"
                if v.isHidden { line += " HIDDEN" }
                if let t = v as? NSTableView { line += " rows=\(t.numberOfRows) cols=\(t.numberOfColumns)" }
                if let f = v as? NSTextField { line += " '\(f.stringValue.prefix(40))'" }
                dump += line + "\n"
                for s in v.subviews { walk(s, depth + 1) }
            }
            walk(view, 0)
            try? dump.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { shoot() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let request = path + ".request"
            if FileManager.default.fileExists(atPath: request) {
                try? FileManager.default.removeItem(atPath: request)
                shoot()
            }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
