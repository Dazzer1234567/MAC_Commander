import AppKit
import SwiftUI

// STUB - replaced by the shortcut properties / icon library / layouts / workspaces port.

struct ShortcutSheet: View {
    let shortcut: Shortcut
    let largestIcon: Double
    let pathNote: String?
    let browse: (() -> String?)?
    let changed: () -> Void
    let onClose: (ShortcutResult) -> Void
    var body: some View { StubSheet(title: "Properties of \(shortcut.label)") { onClose(.cancelled) } }
}

struct LayoutSheet: View {
    let layout: PaneLayout
    let isNew: Bool
    let preview: () -> Void
    let onClose: (ShortcutResult) -> Void
    var body: some View { StubSheet(title: "Layout \(layout.name)") { onClose(.saved) } }
}

struct WorkspacesSheet: View {
    let onClose: () -> Void
    var body: some View { StubSheet(title: "Workspaces") { onClose() } }
}

enum IconLibrary {
    static func setInk(_ color: NSColor) {}

    /// The icon a shortcut shows: its chosen one, else its target's own.
    static func image(for shortcut: Shortcut) -> NSImage? {
        if let source = shortcut.iconSource, !source.hasPrefix("builtin:"),
           let image = NSImage(contentsOfFile: source) { return image }
        guard !shortcut.target.isEmpty, FileManager.default.fileExists(atPath: shortcut.target) else { return nil }
        return NSWorkspace.shared.icon(forFile: shortcut.target)
    }
}
