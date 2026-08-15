import SwiftUI

/// Shared sheet for "New Folder" and "Rename".
struct NameSheet: View {
    let title: String
    let prompt: String
    let initialText: String
    let confirmLabel: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(prompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            text = initialText
            fieldFocused = true
        }
    }

    private func confirm() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onConfirm(text)
        dismiss()
    }
}

struct TrashConfirmSheet: View {
    let items: [FileItem]
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.headline)
                    Text("They go to the Trash, so you can still get them back.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if items.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items.prefix(12)) { item in
                            Text(item.name).font(.system(size: 11)).lineLimit(1)
                        }
                        if items.count > 12 {
                            Text("and \(items.count - 12) more…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private var headline: String {
        items.count == 1
            ? "Move “\(items[0].name)” to the Trash?"
            : "Move \(items.count) items to the Trash?"
    }
}

struct ConflictSheet: View {
    let request: ConflictRequest
    let onDecide: (ConflictDecision, Bool) -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(request.destination.lastPathComponent)” already exists")
                    .font(.headline)
                Text("in \(request.destination.deletingLastPathComponent().path)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack(alignment: .top, spacing: 20) {
                fileSummary("Existing", url: request.destination)
                Divider().frame(height: 44)
                fileSummary("New", url: request.source)
            }

            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)
                .font(.system(size: 11))

            HStack {
                Button("Cancel", role: .cancel) { onDecide(.cancel, applyToAll) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { onDecide(.skip, applyToAll) }
                Button("Keep Both") { onDecide(.keepBoth, applyToAll) }
                Button("Replace") { onDecide(.overwrite, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private func fileSummary(_ label: String, url: URL) -> some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file))
                .font(.system(size: 11))
            Text(values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BookmarksSheet: View {
    @ObservedObject var store: BookmarkStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Bookmark.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bookmarks").font(.headline)

            List(selection: $selection) {
                ForEach(store.items) { bookmark in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bookmark.name).font(.system(size: 12))
                        Text(bookmark.path)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(bookmark.id)
                }
                .onMove { store.move(from: $0, to: $1) }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) { store.remove(store.items[index]) }
                }
            }
            .frame(height: 240)
            .border(Color(nsColor: .separatorColor))

            HStack {
                Button("Add Folder…", action: addFolder)
                Button("Remove") {
                    if let id = selection, let match = store.items.first(where: { $0.id == id }) {
                        store.remove(match)
                        selection = nil
                    }
                }
                .disabled(selection == nil)
                Button("Reset", action: store.resetToDefaults)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Drag to reorder. Bookmarks appear in each pane’s bookmark menu and in the Go menu.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 440)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.add(url)
        }
    }
}
