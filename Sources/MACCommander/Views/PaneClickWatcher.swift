import AppKit
import SwiftUI

/// Notices left-mouse-downs landing inside a pane **without consuming them**,
/// and works out which row was under the cursor.
///
/// The problem this solves: clicking a row in the inactive pane takes two
/// clicks, because SwiftUI spends the first one moving focus and the row never
/// sees it. A local event monitor runs *before* the event reaches any view, so
/// this can activate the pane and select the clicked row from the same click.
///
/// The monitor always returns the event unchanged. That is the important part —
/// an earlier attempt used a `TapGesture` on the rows, which competed with the
/// table's own click handling and broke double-click-to-open. Nothing here
/// swallows an event, so the table still sees both clicks of a double-click.
struct PaneClickWatcher: NSViewRepresentable {
    /// Row index under the cursor, or nil when the click missed every row or
    /// carried a modifier key (in which case selection is left to the table).
    let onClickInside: (Int?) -> Void

    /// Shift-click on a row. Handled entirely here, so the event is swallowed.
    let onShiftClick: (Int) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onClickInside = onClickInside
        view.onShiftClick = onShiftClick
        return view
    }

    func updateNSView(_ nsView: WatcherView, context: Context) {
        nsView.onClickInside = onClickInside
        nsView.onShiftClick = onShiftClick
        nsView.applyTableStyle()
    }

    static func dismantleNSView(_ nsView: WatcherView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class WatcherView: NSView {
        var onClickInside: ((Int?) -> Void)?
        var onShiftClick: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            // The tables may not exist yet on first layout, and the inactive
            // pane can otherwise keep its stripes until something makes it
            // redraw, so try again shortly after appearing.
            applyTableStyle()
            for delay in [0.05, 0.2, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.applyTableStyle()
                }
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else {
                    return event
                }
                let localPoint = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(localPoint) else { return event }
                Self.log("mousedown inside pane, bounds=\(self.bounds.size)")

                let modifiers = event.modifierFlags.intersection([.command, .shift, .option])

                // Shift-click marks a range instead of extending the blue
                // cursor across rows. This is the one case the event must be
                // swallowed: left alive, the table would draw its own multi-row
                // selection over the single-row cursor we want.
                if modifiers == .shift, let row = self.row(under: event) {
                    self.onShiftClick?(row)
                    return nil
                }

                // ⌘-click still belongs to the table.
                self.onClickInside?(modifiers.isEmpty ? self.row(under: event) : nil)
                return event
            }
        }

        /// Maps the click to a row of this pane's table.
        ///
        /// The search starts at the window's content view rather than this
        /// view's `superview`: SwiftUI puts a `.background` view in its own
        /// container, so the table is nowhere near us in the hierarchy. The
        /// click has already been confirmed to be inside this pane, so the one
        /// table whose visible area contains the point is by definition ours.
        private func row(under event: NSEvent) -> Int? {
            guard let content = window?.contentView else {
                Self.log("no content view")
                return nil
            }
            let tables = Self.allTableViews(in: content)
            Self.log("found \(tables.count) table(s)")

            for table in tables {
                guard let scroll = table.enclosingScrollView else { continue }
                let pointInScroll = scroll.convert(event.locationInWindow, from: nil)
                guard scroll.bounds.contains(pointInScroll) else { continue }

                let pointInTable = table.convert(event.locationInWindow, from: nil)
                let row = table.row(at: pointInTable)
                Self.log("hit table, row=\(row)")
                return row >= 0 ? row : nil
            }
            Self.log("click matched no table")
            return nil
        }

        /// SwiftUI gives no control over the selection colour: `.tint` does not
        /// reach a Table's highlight, and the source-list style only rounds it
        /// while still using the system accent. Switching AppKit's own drawing
        /// off lets the cells paint a lighter background themselves.
        func applyTableStyle() {
            guard let content = window?.contentView else { return }
            for table in Self.allTableViews(in: content) {
                table.selectionHighlightStyle = .none
                // Belt and braces with the SwiftUI table style: no zebra striping.
                table.usesAlternatingRowBackgroundColors = false
                // Columns are separated by intercell spacing that lies outside
                // every cell, so no cell background can ever cover it. Closing
                // it is what lets the per-cell slices meet as one solid band.
                if table.intercellSpacing.width != 0 {
                    table.intercellSpacing = NSSize(
                        width: 0, height: table.intercellSpacing.height)
                }
            }
        }

        private static func allTableViews(in view: NSView) -> [NSTableView] {
            var found: [NSTableView] = []
            if let table = view as? NSTableView { found.append(table) }
            for subview in view.subviews {
                found.append(contentsOf: allTableViews(in: subview))
            }
            return found
        }

        /// Enabled by `MACC_DEBUG=1`, or by `touch ~/.maccommander-debug` — the
        /// marker file works when the app is launched detached via `open`,
        /// where an environment variable cannot be passed in.
        static let debugEnabled: Bool = {
            ProcessInfo.processInfo.environment["MACC_DEBUG"] == "1"
                || FileManager.default.fileExists(
                    atPath: NSHomeDirectory() + "/.maccommander-debug")
        }()

        static let logURL = URL(
            fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MACCommander-click.log")

        static func log(_ message: String) {
            guard debugEnabled else { return }
            let line = "[click] \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))

            let fm = FileManager.default
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
