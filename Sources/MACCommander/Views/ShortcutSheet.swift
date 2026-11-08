import AppKit
import SwiftUI

/// Properties of one shortcut: its text, whether that text is shown at all, the full path
/// it points at, which file its icon comes from, and how large that icon is drawn.
///
/// Every edit lands on the shortcut and is redrawn on the bar as it is made, so the size in
/// particular is judged on the button itself, next to its neighbours. Cancel puts back what
/// was there when the sheet opened.
struct ShortcutSheet: View {
    let shortcut: Shortcut
    /// The top of the size slider: as large as the bar this button is on has room for.
    let largestIcon: Double
    /// Shown in place of the path for a button that has none - one of the app's own commands.
    let pathNote: String?
    /// Supplied when the target is something this sheet may change, which puts a Browse
    /// button beside the path. Returns the new target, or nil if the user backed out.
    let browse: (() -> String?)?
    /// Called after each edit so the bar can redraw the button.
    let changed: () -> Void
    let onClose: (ShortcutResult) -> Void

    @Environment(\.ui) private var ui
    @EnvironmentObject private var state: AppState

    @State private var label: String
    @State private var showLabel: Bool
    @State private var target: String
    @State private var iconSource: String?
    @State private var size: Double
    @State private var picking = false

    /// What the shortcut held when the sheet opened, for Cancel to put back.
    private let original: (label: String, showLabel: Bool, target: String, iconSource: String?, iconSize: Double?)

    init(shortcut: Shortcut, largestIcon: Double, pathNote: String?, browse: (() -> String?)?,
         changed: @escaping () -> Void, onClose: @escaping (ShortcutResult) -> Void) {
        self.shortcut = shortcut
        self.largestIcon = largestIcon
        self.pathNote = pathNote
        self.browse = browse
        self.changed = changed
        self.onClose = onClose
        original = (shortcut.label, shortcut.showLabel, shortcut.target, shortcut.iconSource, shortcut.iconSize)
        _label = State(initialValue: shortcut.label)
        _showLabel = State(initialValue: shortcut.showLabel)
        _target = State(initialValue: shortcut.target)
        _iconSource = State(initialValue: shortcut.iconSource)
        _size = State(initialValue: shortcut.iconSize(within: largestIcon))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(14)) {
            Text(label.trimmingCharacters(in: .whitespaces).isEmpty ? "Shortcut" : "Shortcut – \(label.trimmingCharacters(in: .whitespaces))")
                .font(ui.font(13, .semibold)).foregroundStyle(ui.text)
                .lineLimit(1).truncationMode(.tail)
            HStack(alignment: .top, spacing: ui.s(16)) {
                iconColumn
                fields
            }
            HStack(spacing: ui.s(8)) {
                // No confirmation: this only drops a button, the target is untouched, and
                // dragging the item back onto the bar recreates it.
                Button("Delete shortcut") { onClose(.deleted) }
                    .buttonStyle(DazButtonStyle(foreground: ui.marked))
                    .help("Removes the button from the bar. The item it points at is left alone.")
                Spacer()
                Button("OK") { onClose(.saved) }
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(90))
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: cancel)
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(90))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(ui.s(16))
        .frame(width: ui.s(640))
        .background(ui.window)
        .interactiveDismissDisabled()
        .background(EmptyView().sheet(isPresented: $picking) {
            IconPickerSheet(current: iconSource) { chosen in
                picking = false
                if let chosen { iconSource = chosen }
            }
            .environment(\.ui, ui)
        })
        .onChange(of: label) { _, _ in apply() }
        .onChange(of: showLabel) { _, _ in apply() }
        .onChange(of: iconSource) { _, _ in apply() }
        .onChange(of: size) { _, _ in apply() }
    }

    // MARK: - Icon and its size

    /// The preview, drawn at the size the bar draws it, with the size slider running down
    /// the rest of the sheet beneath it.
    private var iconColumn: some View {
        VStack(spacing: ui.s(12)) {
            ZStack {
                ui.panel
                if let icon = previewIcon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: ui.s(size), height: ui.s(size))
                }
            }
            .frame(width: ui.s(64), height: ui.s(64))
            .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))

            VerticalSlider(value: $size, range: Shortcut.smallestIconSize...max(Shortcut.smallestIconSize + 1, largestIcon),
                           reset: Shortcut.usualIconSize)
                // about as tall as the fields beside it, so it runs down the rest of the sheet
                .frame(width: ui.s(24), height: ui.s(148))
                .help("Icon size: up for larger. Double-click to go back to the usual size.")
            Text(size == Shortcut.usualIconSize ? "\(Int(size)) (usual)" : "\(Int(size))")
                .font(ui.font(11)).foregroundStyle(ui.dim)
                .fixedSize()
        }
        .frame(width: ui.s(64))
    }

    /// What the bar will actually show.
    private var previewIcon: NSImage? {
        IconLibrary.image(for: Shortcut(label: "", target: target, iconSource: iconSource))
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("Button text")
            DazTextField(text: $label, font: ui.nsFont(12), textColor: ui.palette.text, background: ui.palette.panel,
                         selectAllOnAppear: true, onSubmit: { onClose(.saved) }, onCancel: cancel)
                .frame(height: ui.s(24))
            Toggle("Show the text on the bar", isOn: $showLabel)
                .toggleStyle(.checkbox)
                .font(ui.font(12)).foregroundStyle(ui.text)
                .padding(.top, ui.s(8))
            Text("Clear the text to leave just the icon.")
                .font(ui.font(11)).foregroundStyle(ui.dim)
                .padding(.top, ui.s(6))

            // A built-in button has no path of its own, so the row says what the button does
            // instead of sitting there empty.
            caption(pathNote == nil ? "Full path" : "Button").padding(.top, ui.s(16))
            HStack(alignment: .center, spacing: ui.s(8)) {
                readOnlyBox(pathNote ?? target, wraps: true)
                if let browse {
                    Button("Browse…") {
                        guard let chosen = browse() else { return }
                        target = chosen
                        apply()
                    }
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(90))
                }
            }

            caption("Icon").padding(.top, ui.s(16))
            HStack(spacing: ui.s(8)) {
                readOnlyBox(iconDescription, wraps: false)
                Button("Library…") { picking = true }
                    .buttonStyle(DazButtonStyle())
                    .help("Pick from the icons bundled with MAC Commander")
                Button("File…", action: chooseIconFile)
                    .buttonStyle(DazButtonStyle())
                    .help("Borrow an icon from any file on disk: an icon, an image or an app")
                Button("Default") { iconSource = nil }
                    .buttonStyle(DazButtonStyle())
                    .help("Go back to the item's own icon")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(ui.font(12)).foregroundStyle(ui.dim).padding(.bottom, ui.s(4))
    }

    /// Read-only but selectable, so a path can be copied out.
    private func readOnlyBox(_ text: String, wraps: Bool) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(ui.mono(11)).foregroundStyle(ui.text)
            .lineLimit(wraps ? nil : 1).truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: wraps)
            .textSelection(.enabled)
            .padding(.horizontal, ui.s(6)).padding(.vertical, ui.s(5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ui.panel)
            .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
    }

    private var iconDescription: String {
        guard let iconSource, !iconSource.isEmpty else { return "(the item's own icon)" }
        if IconLibrary.isBuiltIn(iconSource) {
            let file = (iconSource as NSString).lastPathComponent
            return "library: " + (file as NSString).deletingPathExtension
        }
        return iconSource
    }

    // MARK: - Actions

    /// Writes the current state onto the shortcut and redraws the bar. An empty label is
    /// allowed and means an icon with no text beside it.
    private func apply() {
        shortcut.label = label.trimmingCharacters(in: .whitespaces)
        shortcut.showLabel = showLabel
        shortcut.target = target
        shortcut.iconSource = iconSource
        // The usual size is kept as no size at all. A button nobody has resized then follows
        // the usual size wherever that goes, instead of being pinned to what it once was.
        let rounded = size.rounded()
        shortcut.iconSize = rounded == Shortcut.usualIconSize ? nil : rounded
        changed()
    }

    private func cancel() {
        shortcut.label = original.label
        shortcut.showLabel = original.showLabel
        shortcut.target = original.target
        shortcut.iconSource = original.iconSource
        shortcut.iconSize = original.iconSize
        changed()
        onClose(.cancelled)
    }

    private func chooseIconFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an icon"
        panel.message = "An icon (.icns, .ico, .svg), an image, or an app to borrow the icon of"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: startFolder(for: iconSource.flatMap { IconLibrary.isBuiltIn($0) ? nil : $0 } ?? target))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard IconLibrary.image(source: url.path) != nil else {
            state.warn("No icon could be read from that file.")
            return
        }
        iconSource = url.path
    }

    private func startFolder(for path: String) -> String {
        if path.isEmpty { return Paths.home }
        if Paths.isDirectory(path) && !Shortcut.isApplication(path) { return path }
        let parent = (path as NSString).deletingLastPathComponent
        return Paths.isDirectory(parent) ? parent : Paths.home
    }
}

/// A slider standing on end: up for more. Double-click puts it back to `reset`.
private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reset: Double

    @Environment(\.ui) private var ui
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let thumb = ui.s(14)
            let travel = max(1, geo.size.height - thumb)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = (1 - CGFloat(fraction)) * travel
            ZStack(alignment: .top) {
                // the track, filled below the thumb
                Capsule().fill(ui.border)
                    .frame(width: ui.s(4))
                    .frame(maxHeight: .infinity)
                Capsule().fill(ui.accent)
                    .frame(width: ui.s(4), height: max(0, geo.size.height - y - thumb / 2))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Circle()
                    .fill(hovering ? ui.accent : ui.header)
                    .overlay(Circle().strokeBorder(ui.accent, lineWidth: 1.5))
                    .frame(width: thumb, height: thumb)
                    .offset(y: y)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(TapGesture(count: 2).onEnded { value = reset })
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let share = 1 - Double(min(max(drag.location.y - thumb / 2, 0), travel) / travel)
                let raw = range.lowerBound + share * (range.upperBound - range.lowerBound)
                let stepped = min(max(raw.rounded(), range.lowerBound), range.upperBound)
                if stepped != value { value = stepped }
            })
        }
    }
}
