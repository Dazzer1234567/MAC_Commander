import AppKit
import SwiftUI

/// Batch rename with a live preview, in the style of Total Commander's multi-rename tool.
/// The naming rules live in `RenameEngine`; this is only the dialog around them.
struct MultiRenameSheet: View {
    let urls: [URL]
    let onClose: (_ anythingRenamed: Bool) -> Void

    @Environment(\.ui) private var ui
    @EnvironmentObject private var state: AppState

    /// Everything the user can type or tick, kept as typed so a half-entered number does
    /// not fight back. Any change re-previews.
    private struct Form: Equatable {
        var nameMask = "[N]"
        var extensionMask = "[E]"
        var searchFor = ""
        var replaceWith = ""
        var caseSensitive = false
        var useRegex = false
        var counterStart = "1"
        var counterStep = "1"
        var counterDigits = "1"
        var letterCase: LetterCase = .unchanged
    }

    @State private var form = Form()
    @State private var paths: [String]?
    @State private var plans: [RenamePlan] = []
    @State private var lastBatch: [(from: String, to: String)] = []
    @State private var anythingRenamed = false
    @State private var nameField = FieldHandle()
    @State private var extField = FieldHandle()
    /// Which mask field the placeholder buttons type into: the one last worked in.
    @State private var extLastFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(12)) {
            Text("Multi-rename tool").font(ui.font(13, .semibold)).foregroundStyle(ui.text)
            preview
            HStack(alignment: .top, spacing: ui.s(16)) {
                masks
                counterAndCase.frame(width: ui.s(300))
            }
            actions
        }
        .padding(ui.s(14))
        .frame(width: ui.s(1060), height: ui.s(760))
        .background(ui.window)
        .interactiveDismissDisabled()
        .onAppear {
            if paths == nil { paths = urls.map(\.path) }
            refresh()
        }
        .onChange(of: form) { refresh() }
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { geo in
            let widths = columnWidths(geo.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    header("Old name", widths[0])
                    header("New name", widths[1])
                    header("Status", widths[2])
                    header("Path", widths[3])
                }
                .background(ui.header)
                Rectangle().fill(ui.border).frame(height: 1)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                            row(plan, widths)
                        }
                    }
                }
            }
            .background(ui.panel)
            .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
        }
    }

    /// Old name, new name, status and path, the path taking what is left over.
    private func columnWidths(_ total: CGFloat) -> [CGFloat] {
        let status = ui.s(110)
        let rest = max(0, total - status)
        return [rest * 0.32, rest * 0.32, status, rest * 0.36]
    }

    private func header(_ title: String, _ width: CGFloat) -> some View {
        Text(title)
            .font(ui.font(11, .semibold)).foregroundStyle(ui.dim)
            .lineLimit(1)
            .padding(.horizontal, ui.s(6))
            .frame(width: width, height: ui.s(22), alignment: .leading)
    }

    private func row(_ plan: RenamePlan, _ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            cell(plan.oldName, widths[0], ui.text, mono: true)
            cell(plan.newName, widths[1], ui.text, mono: true)
            cell(statusText(plan.status), widths[2], statusColor(plan.status), mono: false)
            cell((plan.path as NSString).deletingLastPathComponent, widths[3], ui.dim, mono: false, middle: true)
        }
        .frame(height: ui.s(20))
    }

    private func cell(_ text: String, _ width: CGFloat, _ color: Color, mono: Bool, middle: Bool = false) -> some View {
        Text(text)
            .font(mono ? ui.mono(12) : ui.font(12)).foregroundStyle(color)
            .lineLimit(1).truncationMode(middle ? .middle : .tail)
            .padding(.horizontal, ui.s(6))
            .frame(width: width, alignment: .leading)
    }

    private func statusText(_ status: RenameStatus) -> String {
        switch status {
        case .ok: return "rename"
        case .unchanged: return "unchanged"
        case .duplicate: return "name clash"
        case .exists: return "already exists"
        case .invalid: return "invalid name"
        }
    }

    private func statusColor(_ status: RenameStatus) -> Color {
        switch status {
        case .ok: return ui.palette.good.swiftUI
        case .unchanged: return ui.dim
        default: return ui.marked
        }
    }

    // MARK: - Controls

    private var masks: some View {
        VStack(alignment: .leading, spacing: ui.s(4)) {
            label("Rename mask: file name")
            field($form.nameMask, handle: nameField, onFocus: { extLastFocused = false })
            HStack(spacing: ui.s(5)) {
                insertButton("[N] name", "[N]")
                insertButton("[E] ext", "[E]")
                insertButton("[C] count", "[C]")
                insertButton("[d] date", "[d]")
                insertButton("[t] time", "[t]")
                insertButton("[P] folder", "[P]")
            }
            .padding(.top, ui.s(2))

            label("Rename mask: extension").padding(.top, ui.s(10))
            field($form.extensionMask, handle: extField, onFocus: { extLastFocused = true })

            label("Search and replace").padding(.top, ui.s(10))
            HStack(spacing: ui.s(6)) {
                field($form.searchFor)
                field($form.replaceWith)
            }
            HStack(spacing: ui.s(20)) {
                Toggle("Case sensitive", isOn: $form.caseSensitive)
                Toggle("Regular expression", isOn: $form.useRegex)
            }
            .toggleStyle(.checkbox)
            .font(ui.font(12)).foregroundStyle(ui.text)
            .padding(.top, ui.s(4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var counterAndCase: some View {
        VStack(alignment: .leading, spacing: ui.s(4)) {
            label("Counter")
            HStack(spacing: ui.s(6)) {
                numberBox("Start at", $form.counterStart)
                numberBox("Step by", $form.counterStep)
                numberBox("Digits", $form.counterDigits)
            }

            label("Convert case").padding(.top, ui.s(10))
            Picker("", selection: $form.letterCase) {
                ForEach(LetterCase.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(ui.font(12))

            Text(summary)
                .font(ui.font(12)).foregroundStyle(ui.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, ui.s(14))
        }
    }

    private var actions: some View {
        HStack(spacing: ui.s(8)) {
            Button("Reset masks") { form = Form() }
                .buttonStyle(DazButtonStyle())
                .frame(minWidth: ui.s(110))
            Button("Undo rename", action: undo)
                .buttonStyle(DazButtonStyle())
                .frame(minWidth: ui.s(120))
                .disabled(lastBatch.isEmpty)
            Spacer()
            Button("Start!", action: start)
                .buttonStyle(DazButtonStyle())
                .frame(minWidth: ui.s(110))
                .keyboardShortcut(.defaultAction)
                .disabled(readyCount == 0)
            Button("Close") { onClose(anythingRenamed) }
                .buttonStyle(DazButtonStyle())
                .frame(minWidth: ui.s(100))
                .keyboardShortcut(.cancelAction)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(ui.font(12)).foregroundStyle(ui.dim)
    }

    private func field(_ text: Binding<String>, handle: FieldHandle? = nil, alignment: NSTextAlignment = .left,
                       onFocus: @escaping () -> Void = {}) -> some View {
        RenameField(text: text, handle: handle, font: ui.nsMono(12), textColor: ui.palette.text,
                    background: ui.palette.panel, alignment: alignment, onFocus: onFocus,
                    onSubmit: start, onCancel: { onClose(anythingRenamed) })
            .frame(height: ui.s(24))
    }

    private func numberBox(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: ui.s(2)) {
            Text(title).font(ui.font(11)).foregroundStyle(ui.dim)
            field(text, alignment: .right)
        }
    }

    private func insertButton(_ title: String, _ token: String) -> some View {
        Button(title) {
            // Drop the placeholder wherever the caret is in the mask field last worked in.
            (extLastFocused ? extField : nameField).insert(token)
        }
        .buttonStyle(DazButtonStyle(padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)))
    }

    // MARK: - Working

    private var options: RenameOptions {
        RenameOptions(
            nameMask: form.nameMask,
            extensionMask: form.extensionMask,
            searchFor: form.searchFor,
            replaceWith: form.replaceWith,
            caseSensitive: form.caseSensitive,
            useRegex: form.useRegex,
            letterCase: form.letterCase,
            counterStart: Int(form.counterStart.trimmingCharacters(in: .whitespaces)) ?? 1,
            counterStep: Int(form.counterStep.trimmingCharacters(in: .whitespaces)) ?? 1,
            counterDigits: min(max(Int(form.counterDigits.trimmingCharacters(in: .whitespaces)) ?? 1, 1), 10))
    }

    private var readyCount: Int { plans.filter(\.willRename).count }

    private var summary: String {
        let blocked = plans.filter { [.duplicate, .exists, .invalid].contains($0.status) }.count
        return blocked > 0
            ? "\(readyCount) to rename, \(blocked) blocked. Blocked rows are skipped."
            : "\(readyCount) of \(plans.count) will be renamed."
    }

    private func refresh() {
        plans = RenameEngine.buildPlan(paths ?? urls.map(\.path), options)
    }

    private func start() {
        let current = paths ?? urls.map(\.path)
        let fresh = RenameEngine.buildPlan(current, options)
        guard fresh.contains(where: \.willRename) else { return }

        let result = RenameEngine.apply(fresh)

        if result.renamed > 0 {
            anythingRenamed = true
            lastBatch = result.undo
            // Carry on from the new names, so a second pass builds on the first. Rows that
            // were skipped stay in the list under the name they still have.
            let moved = Dictionary(result.undo.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })
            paths = current.map { moved[$0] ?? $0 }
        }

        report(result, "renamed")
        form = Form()
        refresh()
    }

    private func undo() {
        guard !lastBatch.isEmpty else { return }

        let result = RenameEngine.revert(lastBatch)

        if result.renamed > 0 {
            anythingRenamed = true
            let back = Dictionary(lastBatch.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
            paths = (paths ?? []).map { back[$0] ?? $0 }
        }

        lastBatch = []
        report(result, "put back")
        refresh()
    }

    private func report(_ result: RenameOutcome, _ verb: String) {
        guard !result.errors.isEmpty else { return }

        var detail = result.errors.prefix(12).joined(separator: "\n")
        if result.errors.count > 12 { detail += "\n... and \(result.errors.count - 12) more" }

        state.warn("\(result.renamed) \(verb), \(result.errors.count) failed:\n\n\(detail)")
    }
}

/// Lets the dialog reach into a mask field to type a placeholder at its caret.
final class FieldHandle {
    weak var field: NSTextField?

    func insert(_ token: String) {
        guard let field else { return }
        if field.currentEditor() == nil {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        // Typed through the field editor, so the change reports back like a keystroke.
        (field.currentEditor() as? NSTextView)?.insertText(token, replacementRange: field.currentEditor()!.selectedRange)
    }
}

/// A one-line field for the rename dialog: monospaced, reports focus, Return and Escape,
/// and can be typed into from outside through a `FieldHandle`.
private struct RenameField: NSViewRepresentable {
    @Binding var text: String
    var handle: FieldHandle?
    var font: NSFont
    var textColor: NSColor
    var background: NSColor
    var alignment: NSTextAlignment = .left
    var onFocus: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = DazTextField.FocusReportingField()
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.onFocus = { context.coordinator.parent.onFocus() }
        field.stringValue = text
        handle?.field = field
        apply(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        handle?.field = field
        apply(to: field)
        if field.stringValue != text {
            // Set from outside (Reset masks, or the reset after a pass): keep the caret sane.
            field.stringValue = text
        }
    }

    private func apply(to field: NSTextField) {
        field.font = font
        field.textColor = textColor
        field.backgroundColor = background
        field.drawsBackground = true
        field.alignment = alignment
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        init(_ parent: RenameField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
