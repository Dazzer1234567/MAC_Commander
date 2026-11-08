import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Reads file paths out of a drop, on the main queue.
func loadDroppedPaths(_ providers: [NSItemProvider], _ done: @escaping ([String]) -> Void) {
    var paths: [String] = []
    let group = DispatchGroup()
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { DispatchQueue.main.async { paths.append(url.path) } }
            DispatchQueue.main.async { group.leave() }
        }
    }
    group.notify(queue: .main) { done(paths) }
}

/// The identifier a button being rearranged travels under.
private func loadReorderID(_ providers: [NSItemProvider], prefix: String, _ done: @escaping (UUID) -> Void) -> Bool {
    guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) })
    else { return false }
    _ = provider.loadObject(ofClass: NSString.self) { text, _ in
        guard let text = text as? String, text.hasPrefix(prefix),
              let id = UUID(uuidString: String(text.dropFirst(prefix.count))) else { return }
        DispatchQueue.main.async { done(id) }
    }
    return true
}

// MARK: - Workspace toolbar

struct WorkspaceToolbar: View {
    @ObservedObject var state: AppState
    @Environment(\.ui) private var ui

    var body: some View {
        let workspace = state.currentWorkspace
        VStack(spacing: 0) {
            mainRow(workspace)
            ForEach(1..<max(1, workspace.shortcutRows), id: \.self) { row in
                extraRow(workspace, row: row)
            }
        }
    }

    private func mainRow(_ workspace: Workspace) -> some View {
        ShortcutRowFrame(state: state, row: 0) {
            HStack(spacing: 0) {
                workspacePicker
                    .padding(.trailing, ui.s(10))
                ZStack(alignment: .leading) {
                    shortcuts(workspace.buttons(onRow: 0))
                    if workspace.buttons.isEmpty {
                        Text("No shortcuts yet - drag a folder, program or file onto this bar")
                            .font(ui.font(12)).foregroundStyle(ui.dim).allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if let message = state.toolbarMessage {
                        Text(message).font(ui.font(12)).foregroundStyle(ui.accent)
                            .padding(.horizontal, ui.s(6)).background(ui.header)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.trailing, ui.s(10))
                tools
            }
        }
    }

    private func extraRow(_ workspace: Workspace, row: Int) -> some View {
        let buttons = workspace.buttons(onRow: row)
        return ShortcutRowFrame(state: state, row: row) {
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    shortcuts(buttons)
                    if buttons.isEmpty {
                        Text("Empty row - drag a folder, program or file onto it")
                            .font(ui.font(12)).foregroundStyle(ui.dim).allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ui.s(42), alignment: .leading)
                .padding(.leading, ui.s(4))
                .padding(.trailing, ui.s(10))
                toolButton(help: buttons.isEmpty ? "Remove this row"
                           : "Remove this row - its shortcuts move up to the row above") {
                    Glyph.minus.stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: ui.s(20), height: ui.s(20))
                } action: { state.removeShortcutRow(row) }
            }
        }
    }

    private var workspacePicker: some View {
        Menu {
            ForEach(state.settings.workspaces) { workspace in
                Button {
                    state.selectWorkspace(workspace)
                } label: {
                    if workspace === state.currentWorkspace { Label(workspace.name, systemImage: "checkmark") }
                    else { Text(workspace.name) }
                }
            }
        } label: {
            Text(state.currentWorkspace.name).font(ui.font(12))
        }
        .menuStyle(.button)
        .frame(width: ui.s(190), height: ui.s(34))
        .help("Workspace - each one keeps its own set of shortcuts")
        .contextMenu {
            Button("Rename workspace…") { state.renameWorkspace(state.currentWorkspace) }
            Button("Delete workspace") { state.deleteWorkspace(state.currentWorkspace) }
        }
    }

    private func shortcuts(_ list: [Shortcut]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ui.s(4)) {
                ForEach(list) { shortcut in
                    ShortcutButton(state: state, shortcut: shortcut)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var tools: some View {
        HStack(spacing: ui.s(6)) {
            toolButton(help: "Add another row of shortcuts below this one") {
                Glyph.plus.stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: ui.s(20), height: ui.s(20))
            } action: { state.addShortcutRow() }

            toolButton(help: "Pack files into a zip file (⌥F5)") {
                TrayIcon(down: true).fill().frame(width: ui.s(17), height: ui.s(17))
            } action: { state.doPack() }

            toolButton(help: "Unpack archives (⌥F9)") {
                TrayIcon(down: false).fill().frame(width: ui.s(17), height: ui.s(17))
            } action: { state.doUnpack() }

            toolButton(help: "Find files (⌥F7)") {
                Glyph.magnifier.stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .frame(width: ui.s(19), height: ui.s(19))
            } action: { state.doSearch() }

            toolButton(help: "Rearrange this bar - drag the buttons into the order you want",
                       toggled: state.editingShortcuts) {
                Glyph.pencil.stroke(style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                    .frame(width: ui.s(22), height: ui.s(22))
            } action: {
                state.editingShortcuts.toggle()
                if state.editingShortcuts { state.flash("Drag the buttons into the order you want") }
            }

            toolButton(help: "Workspaces - add or remove") {
                Image(systemName: "gearshape").font(.system(size: ui.s(18)))
            } action: { state.manageWorkspaces() }
        }
    }

    private func toolButton<Content: View>(help: String, toggled: Bool = false, @ViewBuilder content: () -> Content,
                                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content().frame(width: ui.s(44), height: ui.s(40))
        }
        .buttonStyle(DazButtonStyle(foreground: toggled ? ui.toggled : nil, padding: EdgeInsets()))
        .help(help)
    }
}

/// One bar of shortcuts: takes drops of new shortcuts, and of buttons being rearranged.
struct ShortcutRowFrame<Content: View>: View {
    @ObservedObject var state: AppState
    let row: Int
    @ViewBuilder let content: () -> Content
    @Environment(\.ui) private var ui
    @State private var targeted = false

    var body: some View {
        content()
            .padding(.horizontal, ui.s(2))
            .padding(.vertical, ui.s(1))
            .barBackground(ui, highlighted: targeted)
            .padding(EdgeInsets(top: 3, leading: 3, bottom: 0, trailing: 3))
            .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
                if loadReorderID(providers, prefix: "shortcut:", { id in
                    if let dragged = state.shortcut(withID: id) { state.moveShortcut(dragged, before: nil, row: row) }
                }) { return true }
                guard !state.editingShortcuts else { return false }
                loadDroppedPaths(providers) { state.dropOnToolbar($0, row: row) }
                return true
            }
    }
}

struct ShortcutButton: View {
    @ObservedObject var state: AppState
    let shortcut: Shortcut
    @Environment(\.ui) private var ui

    var body: some View {
        let hasLabel = shortcut.showLabel && !shortcut.label.trimmingCharacters(in: .whitespaces).isEmpty
        let icon = IconLibrary.image(for: shortcut)
        let size = ui.s(shortcut.iconSize(within: AppState.largestShortcutIcon))
        let button = Button {
            if state.editingShortcuts { return }
            if NSEvent.modifierFlags.contains(.command) { state.editShortcut(shortcut) }
            else { state.runShortcut(shortcut) }
        } label: {
            HStack(spacing: ui.s(8)) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                }
                // With no icon to fall back on, show something regardless.
                if hasLabel || icon == nil {
                    Text(hasLabel ? shortcut.label : (shortcut.target as NSString).lastPathComponent)
                        .font(ui.font(12)).lineLimit(1)
                }
            }
            .frame(height: ui.s(40))
        }
        .buttonStyle(DazButtonStyle(padding: EdgeInsets(top: 0, leading: hasLabel || icon == nil ? 10 : 4,
                                                        bottom: 0, trailing: hasLabel || icon == nil ? 10 : 4)))
        .help(tip(hasLabel: hasLabel))
        .contextMenu {
            Button("Properties…") { state.editShortcut(shortcut) }
            Button("Remove shortcut") { state.removeShortcut(shortcut) }
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
            if loadReorderID(providers, prefix: "shortcut:", { id in
                if let dragged = state.shortcut(withID: id) { state.moveShortcut(dragged, before: shortcut, row: shortcut.row) }
            }) { return true }
            // Files dropped on a program's button are handed to that program.
            guard !state.editingShortcuts, Shortcut.acceptsFiles(shortcut.target) else { return false }
            loadDroppedPaths(providers) { state.openWith(shortcut, paths: $0) }
            return true
        }

        if state.editingShortcuts {
            button.onDrag { NSItemProvider(object: "shortcut:\(shortcut.id.uuidString)" as NSString) }
        } else {
            button
        }
    }

    private func tip(hasLabel: Bool) -> String {
        var tip = hasLabel || shortcut.label.isEmpty ? shortcut.target : "\(shortcut.label)\n\(shortcut.target)"
        if state.opensInPane(shortcut) { tip += "\nClick to open it in the active pane" }
        return tip + "\n⌘-click for its properties"
    }
}

// MARK: - Saved pane layouts

struct LayoutBar: View {
    @ObservedObject var state: AppState
    @Environment(\.ui) private var ui

    var body: some View {
        let layouts = state.currentWorkspace.layouts
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ui.s(5)) {
                        ForEach(layouts) { layout in layoutButton(layout) }
                    }
                    .padding(.vertical, ui.s(2))
                }
                if layouts.isEmpty {
                    Text("No saved layouts - the plus button saves both panes as they are now")
                        .font(ui.font(12)).foregroundStyle(ui.dim).padding(.leading, ui.s(7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, ui.s(10))
            Button { state.addLayout() } label: {
                Text("+").font(ui.font(15, .semibold)).frame(width: ui.s(34), height: ui.s(56))
            }
            .buttonStyle(DazButtonStyle(padding: EdgeInsets()))
            .help("Save the current left and right folders as a layout")
        }
        .padding(.horizontal, ui.s(3))
        .padding(.vertical, ui.s(2))
        .barBackground(ui)
        .padding(EdgeInsets(top: 3, leading: 3, bottom: 0, trailing: 3))
    }

    private func layoutButton(_ layout: PaneLayout) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) { state.editLayout(layout) }
            else { state.applyLayout(layout) }
        } label: {
            VStack(alignment: .leading, spacing: ui.s(2)) {
                Text(layout.name).font(ui.font(12, .semibold)).lineLimit(1).truncationMode(.tail)
                Text(layout.summary).font(ui.font(11)).foregroundStyle(ui.dim).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: ui.s(min(max(layout.width, PaneLayout.minWidth), PaneLayout.maxWidth)) - ui.s(20),
                   height: ui.s(56), alignment: .leading)
        }
        .buttonStyle(DazButtonStyle(padding: EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)))
        .help("\(layout.leftPath)\n\(layout.rightPath)")
        .contextMenu {
            Button("Properties…") { state.editLayout(layout) }
            Button("Update to current panes") { state.updateLayoutToCurrent(layout) }
            Button("Remove layout") { state.removeLayout(layout) }
        }
    }
}

// MARK: - Centre strip

/// The narrow column between the panes, holding the shared commands. It is also the
/// splitter: dragging anywhere on it that is not a button rebalances the panes.
struct CenterStrip: View {
    @ObservedObject var state: AppState
    /// The y of the first list row, so the buttons line up with it.
    let topOffset: CGFloat
    @Environment(\.ui) private var ui
    @State private var targeted = false

    static func width(_ ui: UI) -> CGFloat { ui.s(52) }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(targeted ? ui.accent : ui.header)
            VStack(spacing: 0) {
                ForEach(state.settings.centerBar) { item in
                    CenterButton(state: state, item: item)
                }
                Spacer(minLength: 0)
                Button {
                    state.editingCenter.toggle()
                    if state.editingCenter { state.flash("Drag the centre buttons into the order you want") }
                } label: {
                    Glyph.pencil.stroke(style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                        .frame(width: ui.s(26), height: ui.s(26))
                        .frame(width: ui.s(46), height: ui.s(46))
                }
                .buttonStyle(DazButtonStyle(foreground: state.editingCenter ? ui.toggled : nil, padding: EdgeInsets()))
                .help("Rearrange this strip - drag the buttons into the order you want")
                .padding(.bottom, ui.s(6))
            }
            .padding(.top, topOffset)
        }
        .frame(width: CenterStrip.width(ui))
        .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
            if loadReorderID(providers, prefix: "center:", { id in
                if let dragged = state.centerItem(withID: id) { state.moveCenterItem(dragged, before: nil) }
            }) { return true }
            guard !state.editingCenter else { return false }
            loadDroppedPaths(providers) { state.dropOnCenter($0) }
            return true
        }
    }
}

struct CenterButton: View {
    @ObservedObject var state: AppState
    let item: CenterItem
    @Environment(\.ui) private var ui

    var body: some View {
        let toggled = item.command == CenterItem.scratchpad && state.active.scratchpadVisible
        let button = Button {
            if state.editingCenter { return }
            if NSEvent.modifierFlags.contains(.command) { state.editCenterItem(item) }
            else { state.centerClick(item) }
        } label: {
            content.frame(width: ui.s(46), height: ui.s(46))
        }
        .buttonStyle(DazButtonStyle(toggled: toggled, padding: EdgeInsets()))
        .help(tip)
        .padding(ui.s(3))
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
            if loadReorderID(providers, prefix: "center:", { id in
                if let dragged = state.centerItem(withID: id) { state.moveCenterItem(dragged, before: item) }
            }) { return true }
            guard !state.editingCenter, let shortcut = item.shortcut, !item.isBuiltIn,
                  Shortcut.acceptsFiles(shortcut.target) else { return false }
            loadDroppedPaths(providers) { state.openWith(shortcut, paths: $0) }
            return true
        }

        if state.editingCenter {
            button.onDrag { NSItemProvider(object: "center:\(item.id.uuidString)" as NSString) }
        } else {
            button
        }
    }

    /// A chosen icon wins over everything, then a label the user asked to see, and only
    /// then the button's own drawing. Letters and glyphs follow the icon-size slider too.
    @ViewBuilder private var content: some View {
        let look = item.look
        let size = look.iconSize(within: AppState.largestCenterIcon)
        let scale = size / Shortcut.usualIconSize
        if look.iconSource?.isEmpty == false, let chosen = IconLibrary.image(for: look) {
            Image(nsImage: chosen).resizable().interpolation(.high).frame(width: ui.s(size), height: ui.s(size))
        } else if look.showLabel && !look.label.trimmingCharacters(in: .whitespaces).isEmpty {
            letters(shortLabel(look), 15 * scale)
        } else if !item.isBuiltIn {
            if let icon = IconLibrary.image(for: look) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: ui.s(size), height: ui.s(size))
            } else {
                letters(shortLabel(look), 15 * scale)
            }
        } else {
            switch item.command {
            case CenterItem.volume: letters("V", 26 * scale)
            case CenterItem.scratchpad: letters("T", 26 * scale)
            case CenterItem.copyName: letters("P", 26 * scale)
            case CenterItem.copyPath: letters("FP", 25 * scale)
            case CenterItem.search: glyph(Glyph.magnifier, 30 * scale, 2.2)
            case CenterItem.match: glyph(Glyph.match, 30 * scale, 2.6)
            case CenterItem.quickFolder: glyph(Glyph.downArrow, 32 * scale, 2.8)
            default: letters("?", 20 * scale)
            }
        }
    }

    private func letters(_ text: String, _ size: Double) -> some View {
        Text(text).font(ui.font(size, .bold))
    }

    private func glyph(_ shape: Glyph, _ size: Double, _ thickness: CGFloat) -> some View {
        shape.stroke(style: StrokeStyle(lineWidth: thickness * ui.s(size) / 24, lineCap: .round, lineJoin: .round))
            .frame(width: ui.s(size), height: ui.s(size))
    }

    /// Two characters at most: the strip is only one button wide.
    private func shortLabel(_ shortcut: Shortcut) -> String {
        var name = shortcut.label.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = Paths.leaf(shortcut.target) }
        return String(name.prefix(2)).uppercased()
    }

    private var tip: String {
        if !item.isBuiltIn, let shortcut = item.shortcut {
            var tip = "\(shortcut.label)\n\(shortcut.target)"
            if state.opensInPane(shortcut) { tip += "\nClick to open it in the active pane" }
            return tip + "\n⌘-click for its properties"
        }
        switch item.command {
        case CenterItem.volume: return "Go to \(state.settings.volumePath) in the active pane\n⌘-click to change it"
        case CenterItem.match: return "Match - show the active pane's folder in the other pane"
        case CenterItem.quickFolder:
            return "Go to \(state.settings.quickFolder) in the active pane\n⌘-click to change it"
        case CenterItem.scratchpad: return "Toggle the active pane into a plain-text scratchpad"
        case CenterItem.copyName: return "Copy the name to the clipboard"
        case CenterItem.copyPath: return "Copy the full path to the clipboard"
        case CenterItem.search: return "Find files (⌥F7)"
        default: return ""
        }
    }
}

// MARK: - Command line and function keys

struct CommandLineBar: View {
    @ObservedObject var state: AppState
    @Environment(\.ui) private var ui
    @State private var text = ""

    var body: some View {
        HStack(spacing: ui.s(6)) {
            Text(state.active.currentPath + ">")
                .font(ui.mono(12)).foregroundStyle(ui.dim)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: ui.s(420), alignment: .trailing)
            DazTextField(text: $text, font: ui.nsMono(12), textColor: ui.palette.text, background: ui.palette.panel,
                         onSubmit: {
                             let command = text
                             text = ""
                             state.runCommand(command)
                         },
                         onCancel: {
                             text = ""
                             state.active.focusRequest += 1
                         })
                .frame(height: ui.s(22))
        }
        .padding(EdgeInsets(top: 0, leading: 5, bottom: 3, trailing: 3))
    }
}

struct FunctionKeyBar: View {
    @ObservedObject var state: AppState
    @Environment(\.ui) private var ui

    var body: some View {
        HStack(spacing: 2) {
            key("F3 View", "View the file - F3 or ⌘3") { state.doView() }
            key("F4 Edit", "Open in the editor - F4 or ⌘4") { state.doEdit() }
            key("F5 Copy", "Copy to the other pane - F5 or ⌘5") { state.doTransfer(move: false) }
            key("F6 Move", "Move to the other pane - F6 or ⌘6") { state.doTransfer(move: true) }
            key("F7 NewDir", "New folder - F7 or ⌘7") { state.doNewFolder() }
            key("F8 Delete", "Move to the Trash - F8 or ⌘8") { state.doDelete(toTrash: true) }
            key("⌘Q Exit", "Quit MAC Commander") { NSApp.terminate(nil) }
        }
        .padding(EdgeInsets(top: 0, leading: 3, bottom: 3, trailing: 3))
    }

    private func key(_ title: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(DazButtonStyle(background: ui.palette.fnKey.swiftUI, padding: EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)))
        .help(help)
    }
}

// MARK: - Progress boxes

/// The floating boxes of the operations running in the background, stacked upwards from
/// the bottom-right corner. Each can be dragged elsewhere by its title.
struct JobBoxes: View {
    @ObservedObject var jobs: JobCenter
    @Environment(\.ui) private var ui

    var body: some View {
        VStack(alignment: .trailing, spacing: ui.s(8)) {
            ForEach(Array(jobs.slots.enumerated().reversed()), id: \.offset) { _, job in
                if let job { JobBox(job: job) } else { Color.clear.frame(width: ui.s(340), height: ui.s(118)) }
            }
        }
        .padding(ui.s(8))
    }
}

struct JobBox: View {
    @ObservedObject var job: Job
    @Environment(\.ui) private var ui
    @State private var dragStart: CGSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(job.title)
                .font(ui.font(12, .semibold)).foregroundStyle(ui.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ui.s(10)).padding(.vertical, ui.s(6))
                .background(ui.header)
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = job.offset }
                        job.offset = CGSize(width: dragStart!.width + value.translation.width,
                                            height: dragStart!.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = nil })
            VStack(alignment: .leading, spacing: ui.s(6)) {
                Text(job.item).font(ui.font(12)).foregroundStyle(ui.text).lineLimit(1).truncationMode(.middle)
                ProgressView(value: job.fraction).tint(ui.accent)
                HStack {
                    Text(job.countText).font(ui.font(11)).foregroundStyle(ui.dim)
                    Spacer()
                    Button("Cancel") { job.cancelRequested = true }
                        .buttonStyle(DazButtonStyle())
                        .disabled(job.cancelRequested)
                }
            }
            .padding(ui.s(10))
        }
        .frame(width: ui.s(340))
        .background(ui.window)
        .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
        .shadow(radius: 6)
        .offset(job.offset)
    }
}
