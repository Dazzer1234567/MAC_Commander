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

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onClickInside = onClickInside
        return view
    }

    func updateNSView(_ nsView: WatcherView, context: Context) {
        nsView.onClickInside = onClickInside
    }

    static func dismantleNSView(_ nsView: WatcherView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class WatcherView: NSView {
        var onClickInside: ((Int?) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else {
                    return event
                }
                let localPoint = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(localPoint) else { return event }
                Self.log("mousedown inside pane, bounds=\(self.bounds.size)")

                // ⌘/⇧ clicks extend a selection; that is the table's job, not ours.
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option])
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

        private static func allTableViews(in view: NSView) -> [NSTableView] {
            var found: [NSTableView] = []
            if let table = view as? NSTableView { found.append(table) }
            for subview in view.subviews {
                found.append(contentsOf: allTableViews(in: subview))
            }
            return found
        }

        static let debugEnabled = ProcessInfo.processInfo.environment["MACC_DEBUG"] == "1"

        static func log(_ message: String) {
            guard debugEnabled else { return }
            FileHandle.standardError.write(Data("[click] \(message)\n".utf8))
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
