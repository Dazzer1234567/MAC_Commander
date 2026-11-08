import SwiftUI

/// Manages the set of workspaces: what there is, adding one, renaming and removing one.
///
/// Like the toolbar's own menu, changes land as they are made, so there is only a Close
/// button. There is always at least one workspace, and names are unique whatever their case:
/// the questions and the checks are AppState's, shared with the toolbar.
struct WorkspacesSheet: View {
    let onClose: () -> Void

    @Environment(\.ui) private var ui
    @EnvironmentObject private var state: AppState
    @State private var hovered: Workspace.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(8)) {
            Text("Workspaces").font(ui.font(13, .semibold)).foregroundStyle(ui.text)
            Text("Each workspace keeps its own shortcuts and saved layouts.")
                .font(ui.font(12)).foregroundStyle(ui.dim)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.settings.workspaces) { workspace in row(workspace) }
                }
            }
            .frame(minHeight: ui.s(240))
            .background(ui.panel)
            .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
            HStack(spacing: ui.s(8)) {
                Button("+  Add workspace") { Task { await state.addWorkspace() } }
                    .buttonStyle(DazButtonStyle())
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(100))
                    .keyboardShortcut(.defaultAction)
                    // Escape closes too
                    .background(Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0))
            }
            .padding(.top, ui.s(6))
        }
        .padding(ui.s(16))
        .frame(width: ui.s(480), height: ui.s(420))
        .background(ui.window)
    }

    private func row(_ workspace: Workspace) -> some View {
        let showing = workspace.name == state.settings.activeWorkspace
        return HStack(spacing: ui.s(8)) {
            VStack(alignment: .leading, spacing: ui.s(2)) {
                HStack(spacing: ui.s(6)) {
                    Text(workspace.name).font(ui.font(13, showing ? .semibold : .regular)).foregroundStyle(ui.text)
                    if showing { Text("showing").font(ui.font(10)).foregroundStyle(ui.accent) }
                }
                Text("\(count(workspace.buttons.count, "shortcut")), \(count(workspace.layouts.count, "layout"))")
                    .font(ui.font(11)).foregroundStyle(ui.dim)
            }
            Spacer(minLength: ui.s(8))
            Button("Rename") { state.renameWorkspace(workspace) }
                .buttonStyle(DazButtonStyle())
            Button("Delete") { state.deleteWorkspace(workspace) }
                .buttonStyle(DazButtonStyle(foreground: ui.marked))
        }
        .padding(.horizontal, ui.s(8)).padding(.vertical, ui.s(6))
        .background(hovered == workspace.id ? ui.hover : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = workspace.id } else if hovered == workspace.id { hovered = nil }
        }
        .onTapGesture(count: 2) { state.renameWorkspace(workspace) }
        .help("Double-click to rename")
    }

    private func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// Leaves the active workspace pointing at one that still exists.
    private func close() {
        if !state.settings.workspaces.contains(where: { $0.name == state.settings.activeWorkspace }),
           let first = state.settings.workspaces.first {
            state.settings.activeWorkspace = first.name
            state.changed()
        }
        onClose()
    }
}
