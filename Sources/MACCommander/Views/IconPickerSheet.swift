import AppKit
import SwiftUI

/// Gallery of the icons bundled with the app, grouped by the subfolder they sit in. Hands
/// back the chosen icon's `builtin:` reference, or nil when cancelled.
struct IconPickerSheet: View {
    /// The shortcut's current icon, so reopening starts on the current choice.
    let current: String?
    let onClose: (String?) -> Void

    @Environment(\.ui) private var ui
    @State private var filter = ""
    @State private var selected: BuiltInIcon?
    @State private var hovered: BuiltInIcon.ID?

    /// Icons that can actually be drawn. One that cannot is left out rather than shown blank.
    private static var usable: [BuiltInIcon] { IconLibrary.all.filter { IconLibrary.image(for: $0) != nil } }

    init(current: String?, onClose: @escaping (String?) -> Void) {
        self.current = current
        self.onClose = onClose
        _selected = State(initialValue: current.flatMap(IconLibrary.builtIn))
    }

    var body: some View {
        let all = Self.usable
        let shown = matching(all)
        VStack(alignment: .leading, spacing: ui.s(10)) {
            Text("Choose an icon").font(ui.font(13, .semibold)).foregroundStyle(ui.text)
            HStack(spacing: ui.s(12)) {
                DazTextField(text: $filter, font: ui.nsFont(12), textColor: ui.palette.text,
                             background: ui.palette.panel, focusOnAppear: true,
                             onSubmit: accept, onCancel: { onClose(nil) })
                    .frame(height: ui.s(24))
                Text(shown.count == all.count ? "\(all.count) icons" : "\(shown.count) of \(all.count)")
                    .font(ui.font(12)).foregroundStyle(ui.dim)
                    .fixedSize()
            }
            gallery(shown)
                .background(ui.panel)
                .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
            HStack(spacing: ui.s(8)) {
                Text(selectedText).font(ui.font(12)).foregroundStyle(ui.dim)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Use this icon", action: accept)
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(120))
                    .disabled(selected == nil)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { onClose(nil) }
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(90))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(ui.s(12))
        .frame(width: ui.s(820), height: ui.s(620))
        .background(ui.window)
    }

    /// The filter matches the name or the group, so typing a group's name shows all of it.
    private func matching(_ all: [BuiltInIcon]) -> [BuiltInIcon] {
        let typed = filter.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(typed) || $0.group.localizedCaseInsensitiveContains(typed) }
    }

    private func gallery(_ shown: [BuiltInIcon]) -> some View {
        let groups = Dictionary(grouping: shown, by: \.group)
        // the top of the folder first, then the subfolders in order
        let names = groups.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ui.s(100), maximum: ui.s(110)), spacing: ui.s(4))],
                          alignment: .leading, spacing: ui.s(4), pinnedViews: [.sectionHeaders]) {
                    ForEach(names, id: \.self) { group in
                        Section {
                            ForEach(groups[group] ?? []) { icon in cell(icon).id(icon.id) }
                        } header: {
                            if names.count > 1 || !group.isEmpty {
                                Text(group.isEmpty ? "Icons" : group)
                                    .font(ui.font(11, .semibold)).foregroundStyle(ui.dim)
                                    .padding(.horizontal, ui.s(6)).padding(.vertical, ui.s(4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(ui.panel)
                            }
                        }
                    }
                }
                .padding(ui.s(6))
            }
            .onAppear {
                if let id = selected?.id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func cell(_ icon: BuiltInIcon) -> some View {
        let isSelected = selected?.id == icon.id
        return VStack(spacing: ui.s(6)) {
            if let image = IconLibrary.image(for: icon) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: ui.s(48), height: ui.s(48))
            }
            Text(icon.name)
                .font(ui.font(10)).foregroundStyle(ui.text)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: ui.s(92))
        }
        .frame(width: ui.s(100), height: ui.s(98))
        .background(RoundedRectangle(cornerRadius: 3)
            .fill(isSelected ? ui.palette.cursor.swiftUI : hovered == icon.id ? ui.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isSelected ? ui.accent : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .help(icon.group.isEmpty ? icon.name : "\(icon.group) / \(icon.name)")
        .onHover { inside in
            if inside { hovered = icon.id } else if hovered == icon.id { hovered = nil }
        }
        .onTapGesture(count: 2) {
            selected = icon
            accept()
        }
        .simultaneousGesture(TapGesture().onEnded { selected = icon })
    }

    private var selectedText: String {
        guard let selected else { return "" }
        return selected.group.isEmpty ? selected.name : "\(selected.group) / \(selected.name)"
    }

    private func accept() {
        guard let selected else { return }
        onClose(selected.reference)
    }
}
