import AppKit
import SwiftUI

/// A single-line text field that can select all its text as it opens and reports Return
/// and Escape. SwiftUI's own field can do neither reliably.
struct DazTextField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var background: NSColor
    var selectAllOnAppear = false
    var focusOnAppear = false
    var focusTrigger = 0
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingField()
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.onFocus = { context.coordinator.parent.onFocus() }
        apply(to: field)
        field.stringValue = text
        if focusOnAppear || selectAllOnAppear {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                if self.selectAllOnAppear { field.currentEditor()?.selectAll(nil) }
                else { field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0) }
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        apply(to: field)
        if field.currentEditor() == nil && field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastTrigger != focusTrigger {
            context.coordinator.lastTrigger = focusTrigger
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    private func apply(to field: NSTextField) {
        field.font = font
        field.textColor = textColor
        field.backgroundColor = background
        field.drawsBackground = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DazTextField
        var lastTrigger = 0
        init(_ parent: DazTextField) { self.parent = parent; lastTrigger = parent.focusTrigger }

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

    final class FocusReportingField: NSTextField {
        var onFocus: () -> Void = {}
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus() }
            return became
        }
    }
}

/// The app's own input, confirmation and warning box.
struct PromptSheet: View {
    let request: PromptRequest
    let finish: (String?) -> Void

    @Environment(\.ui) private var ui
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(12)) {
            Text(request.title).font(ui.font(13, .semibold)).foregroundStyle(ui.text)
            switch request.kind {
            case .input(let prompt, let initial, let selectAll):
                Text(prompt).font(ui.font(12)).foregroundStyle(ui.text)
                DazTextField(text: $text, font: ui.nsFont(12), textColor: ui.palette.text,
                             background: ui.palette.panel, selectAllOnAppear: selectAll, focusOnAppear: true,
                             onSubmit: { finish(text) }, onCancel: { finish(nil) })
                    .frame(height: ui.s(24))
                    .onAppear { text = initial }
                buttons(ok: "OK", cancel: true)
            case .confirm(let message, let ok):
                Text(message).font(ui.font(12)).foregroundStyle(ui.text)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(ok: ok, cancel: true)
            case .warn(let message):
                Text(message).font(ui.font(12)).foregroundStyle(ui.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                buttons(ok: "OK", cancel: false)
            }
        }
        .padding(ui.s(18))
        .frame(width: ui.s(isInput ? 560 : 520))
        .background(ui.window)
    }

    private var isInput: Bool {
        if case .input = request.kind { return true }
        return false
    }

    private func buttons(ok: String, cancel: Bool) -> some View {
        HStack(spacing: ui.s(8)) {
            Spacer()
            Button(ok) { finish(text) }
                .buttonStyle(DazButtonStyle())
                .frame(minWidth: ui.s(90))
                .keyboardShortcut(.defaultAction)
            if cancel {
                Button("Cancel") { finish(nil) }
                    .buttonStyle(DazButtonStyle())
                    .frame(minWidth: ui.s(90))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct ConflictSheet: View {
    let request: ConflictRequest
    let onDecide: (ConflictDecision, Bool) -> Void

    @Environment(\.ui) private var ui
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(14)) {
            VStack(alignment: .leading, spacing: ui.s(4)) {
                Text("\"\(request.destination.lastPathComponent)\" already exists")
                    .font(ui.font(13, .semibold)).foregroundStyle(ui.text)
                Text("in \(request.destination.deletingLastPathComponent().path)")
                    .font(ui.font(11)).foregroundStyle(ui.dim)
                    .lineLimit(2).truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: ui.s(20)) {
                fileSummary("Existing", url: request.destination)
                fileSummary("New", url: request.source)
            }
            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)
                .font(ui.font(11)).foregroundStyle(ui.text)
            HStack(spacing: ui.s(8)) {
                Button("Cancel") { onDecide(.cancel, applyToAll) }
                    .buttonStyle(DazButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { onDecide(.skip, applyToAll) }.buttonStyle(DazButtonStyle())
                Button("Keep Both") { onDecide(.keepBoth, applyToAll) }.buttonStyle(DazButtonStyle())
                Button("Replace") { onDecide(.overwrite, applyToAll) }
                    .buttonStyle(DazButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(ui.s(18))
        .frame(width: ui.s(480))
        .background(ui.window)
        .interactiveDismissDisabled()
    }

    private func fileSummary(_ label: String, url: URL) -> some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return VStack(alignment: .leading, spacing: ui.s(2)) {
            Text(label).font(ui.font(10, .semibold)).foregroundStyle(ui.dim)
            Text(Listing.formatBytes(Int64(values?.fileSize ?? 0))).font(ui.font(11)).foregroundStyle(ui.text)
            Text(values?.contentModificationDate.map { FileItem.dateFormatter.string(from: $0) } ?? "—")
                .font(ui.font(11)).foregroundStyle(ui.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BookmarksSheet: View {
    @ObservedObject var store: BookmarkStore
    let onClose: () -> Void
    @Environment(\.ui) private var ui
    @State private var selection: Bookmark.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(12)) {
            Text("Bookmarks").font(ui.font(13, .semibold)).foregroundStyle(ui.text)
            List(selection: $selection) {
                ForEach(store.items) { bookmark in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bookmark.name).font(ui.font(12))
                        Text(bookmark.path).font(ui.font(10)).foregroundStyle(ui.dim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .tag(bookmark.id)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .frame(height: ui.s(240))
            HStack {
                Button("Add Folder…", action: addFolder).buttonStyle(DazButtonStyle())
                Button("Remove") {
                    if let id = selection, let match = store.items.first(where: { $0.id == id }) {
                        store.remove(match)
                        selection = nil
                    }
                }
                .buttonStyle(DazButtonStyle())
                .disabled(selection == nil)
                Button("Reset", action: store.resetToDefaults).buttonStyle(DazButtonStyle())
                Spacer()
                Button("Done", action: onClose).buttonStyle(DazButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Text("Drag to reorder. Bookmarks are in the Go menu.")
                .font(ui.font(10)).foregroundStyle(ui.dim)
        }
        .padding(ui.s(18))
        .frame(width: ui.s(460))
        .background(ui.window)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { store.add(url) }
    }
}

/// Shows the top level of an archive without going into it.
struct PeekSheet: View {
    let item: FileItem
    let onClose: () -> Void

    @Environment(\.ui) private var ui
    @State private var listing: ArchiveListing?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(12)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(ui.font(13, .semibold)).foregroundStyle(ui.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(ui.font(11)).foregroundStyle(ui.dim)
            }
            Group {
                if let failure {
                    Text("Can't read this archive:\n\(failure)").foregroundStyle(ui.text)
                } else if let listing {
                    List(listing.topLevel) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if entry.isDirectory {
                                Text(Listing.plural(entry.childCount, "item")).foregroundStyle(ui.dim)
                            }
                        }
                        .font(ui.font(12))
                    }
                } else {
                    ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: ui.s(280))
            HStack {
                Text("Top level only — nothing inside the folders is listed.")
                    .font(ui.font(10)).foregroundStyle(ui.dim)
                Spacer()
                Button("Done", action: onClose).buttonStyle(DazButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(ui.s(18))
        .frame(width: ui.s(500))
        .background(ui.window)
        .task {
            do {
                listing = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.listTopLevel(of: item.url)
                }.value
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private var subtitle: String {
        guard let listing else { return Listing.formatBytes(item.size) }
        return "\(Listing.formatBytes(item.size)) · \(listing.topLevel.count) at the top level · \(listing.totalEntries) in total"
    }
}
