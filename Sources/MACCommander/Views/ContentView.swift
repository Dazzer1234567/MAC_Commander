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
            WindowSetup.snapshotIfAsked(window)
        }
        return view
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
