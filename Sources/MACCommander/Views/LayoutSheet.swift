import AppKit
import SwiftUI

/// Names a saved pane pair and sets how wide its button is. Used both when saving one from
/// the current panes and when editing an existing one.
///
/// Every edit lands on the layout as it is made, so the button behind the sheet shows how
/// it will look; Cancel puts back what was there.
struct LayoutSheet: View {
    let layout: PaneLayout
    let isNew: Bool
    /// Called on every edit so the bar can redraw the button.
    let preview: () -> Void
    let onClose: (ShortcutResult) -> Void

    @Environment(\.ui) private var ui
    @EnvironmentObject private var state: AppState

    @State private var name: String
    @State private var width: Double
    /// The box is its own text while being typed in, and only becomes the width when it
    /// reads as a number.
    @State private var widthText: String

    private let original: (name: String, width: Double)

    init(layout: PaneLayout, isNew: Bool, preview: @escaping () -> Void, onClose: @escaping (ShortcutResult) -> Void) {
        self.layout = layout
        self.isNew = isNew
        self.preview = preview
        self.onClose = onClose
        original = (layout.name, layout.width)
        let clamped = LayoutSheet.clamp(layout.width)
        _name = State(initialValue: layout.name)
        _width = State(initialValue: clamped)
        _widthText = State(initialValue: String(Int(clamped)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Save pane layout" : "Pane layout – \(original.name)")
                .font(ui.font(13, .semibold)).foregroundStyle(ui.text)
                .lineLimit(1).truncationMode(.tail)
                .padding(.bottom, ui.s(14))

            caption("Name")
            DazTextField(text: $name, font: ui.nsFont(12), textColor: ui.palette.text, background: ui.palette.panel,
                         selectAllOnAppear: true, onSubmit: ok, onCancel: cancel)
                .frame(height: ui.s(24))

            caption("Button width").padding(.top, ui.s(16))
            HStack(spacing: ui.s(12)) {
                Slider(value: Binding(get: { width }, set: { setWidth($0) }),
                       in: PaneLayout.minWidth...PaneLayout.maxWidth, step: 10)
                    .controlSize(.small)
                DazTextField(text: $widthText, font: ui.nsMono(12), textColor: ui.palette.text,
                             background: ui.palette.panel, onSubmit: commitWidthBox, onCancel: cancel)
                    .frame(width: ui.s(80), height: ui.s(24))
            }

            caption("Left pane").padding(.top, ui.s(16))
            readOnlyBox(layout.leftPath)
            caption("Right pane").padding(.top, ui.s(12))
            readOnlyBox(layout.rightPath)

            HStack(spacing: ui.s(8)) {
                if !isNew {
                    Button("Delete layout") { onClose(.deleted) }
                        .buttonStyle(DazButtonStyle(foreground: ui.marked))
                        .help("Removes the button. The folders themselves are left alone.")
                }
                Spacer()
                Button("OK", action: ok)
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(90))
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: cancel)
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(90))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, ui.s(20))
        }
        .padding(ui.s(16))
        .frame(width: ui.s(640))
        .background(ui.window)
        .interactiveDismissDisabled()
        .onChange(of: name) { _, _ in apply() }
        .onChange(of: widthText) { _, typed in
            // a number as it is typed resizes the button straight away; anything else waits
            if let value = Double(typed.trimmingCharacters(in: .whitespaces)) {
                width = LayoutSheet.clamp(value)
                apply()
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(ui.font(12)).foregroundStyle(ui.dim).padding(.bottom, ui.s(4))
    }

    private func readOnlyBox(_ text: String) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(ui.mono(11)).foregroundStyle(ui.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, ui.s(6)).padding(.vertical, ui.s(5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ui.panel)
            .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.rounded(), PaneLayout.minWidth), PaneLayout.maxWidth)
    }

    // The slider and the box are two views of one number, so each updates the other.
    private func setWidth(_ value: Double) {
        width = LayoutSheet.clamp(value)
        widthText = String(Int(width))
        apply()
    }

    /// Takes what is in the box, or puts back what the slider still holds.
    private func commitWidthBox() {
        if let typed = Double(widthText.trimmingCharacters(in: .whitespaces)) { setWidth(typed) }
        else { setWidth(width) }
    }

    private func apply() {
        layout.name = name.trimmingCharacters(in: .whitespaces)
        layout.width = width
        preview()
    }

    private func ok() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            state.warn("Give the layout a name.")
            return
        }
        commitWidthBox()
        onClose(.saved)
    }

    private func cancel() {
        layout.name = original.name
        layout.width = original.width
        preview()
        onClose(.cancelled)
    }
}
