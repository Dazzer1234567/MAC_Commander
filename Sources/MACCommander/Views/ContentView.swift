import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var transfer: TransferController
    @FocusState private var focusedSide: Side?

    init(state: AppState) {
        self.state = state
        self.transfer = state.transfer
    }

    var body: some View {
        VStack(spacing: 0) {
            quickBar
            Divider()
            splitArea
            if let progress = transfer.progress {
                Divider()
                TransferBar(progress: progress) { transfer.cancel() }
            }
            Divider()
            CommandBar(state: state)
        }
        .onChange(of: focusedSide) { _, newValue in
            if let newValue { state.activeSide = newValue }
        }
        .onAppear { focusedSide = .left }
        .sheet(item: $state.sheet) { kind in
            sheetContent(for: kind)
        }
        .sheet(item: $transfer.conflict) { request in
            ConflictSheet(request: request) { decision, applyToAll in
                transfer.resolve(decision, applyToAll: applyToAll)
            }
        }
        .alert(
            "Some items could not be handled",
            isPresented: Binding(
                get: { !state.errorReport.isEmpty },
                set: { if !$0 { state.errorReport = [] } }
            )
        ) {
            Button("OK", role: .cancel) { state.errorReport = [] }
        } message: {
            Text(state.errorReport.prefix(10).joined(separator: "\n"))
        }
    }

    private static let handleWidth: CGFloat = 6
    private static let minPaneWidth: CGFloat = 220

    /// A split laid out by hand rather than with `HSplitView`, because
    /// HSplitView offers no way to set the divider position and is not
    /// dependably backed by an NSSplitView we could drive instead. Owning the
    /// width outright is what makes Fit a one-line reset.
    private var splitArea: some View {
        GeometryReader { geometry in
            let fixed = CenterBar.width + Self.handleWidth
            let evenSplit = max(Self.minPaneWidth, (geometry.size.width - fixed) / 2)
            let widest = max(Self.minPaneWidth, geometry.size.width - fixed - Self.minPaneWidth)
            let leftWidth = min(max(state.leftPaneWidth ?? evenSplit, Self.minPaneWidth), widest)

            HStack(spacing: 0) {
                PaneView(pane: state.left, state: state, side: .left, focusedSide: $focusedSide)
                    .frame(width: leftWidth)
                dragHandle
                CenterBar(state: state)
                    .frame(width: CenterBar.width)
                PaneView(pane: state.right, state: state, side: .right, focusedSide: $focusedSide)
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "split")
        }
    }

    private var dragHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Self.handleWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                    .onChanged { value in
                        state.leftPaneWidth = value.location.x
                    }
            )
    }

    private var quickBar: some View {
        HStack(spacing: 6) {
            Button {
                state.left.navigate(to: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads"))
                focusedSide = .left
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            .help("Show Downloads in the left pane")

            if !state.links.items.isEmpty {
                Divider().frame(height: 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.links.items) { link in
                        linkButton(link)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.regular)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// A folder pinned with the Link button. Clicking it walks the active pane
    /// back into that folder.
    private func linkButton(_ link: Bookmark) -> some View {
        Button {
            state.active.navigate(to: link.url)
        } label: {
            Label(link.name, systemImage: "folder.fill")
                .lineLimit(1)
        }
        .help("Go to \(link.path)")
        .contextMenu {
            Button("Remove Link") { state.links.remove(link) }
            Button("Remove All Links") { state.links.removeAll() }
        }
    }

    @ViewBuilder
    private func sheetContent(for kind: SheetKind) -> some View {
        switch kind {
        case .newFolder:
            NameSheet(
                title: "New Folder",
                prompt: "Create in \(state.active.directory.lastPathComponent)",
                initialText: "untitled folder",
                confirmLabel: "Create"
            ) { name in
                state.performNewFolder(named: name)
            }
        case .rename(let item):
            NameSheet(
                title: "Rename",
                prompt: item.name,
                initialText: item.name,
                confirmLabel: "Rename"
            ) { name in
                state.performRename(item, to: name)
            }
        case .confirmTrash(let items):
            TrashConfirmSheet(items: items) {
                state.performTrash(items)
            }
        case .manageBookmarks:
            BookmarksSheet(store: state.bookmarks)
        case .peekArchive(let item):
            PeekSheet(item: item)
        }
    }
}

/// The Total Commander style function-key strip along the bottom of the window.
struct CommandBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            key("Rename", shortcut: "F2", alt: "⇧⌘E") { state.requestRename() }
            key("Copy", shortcut: "F5", alt: "⇧⌘C") { state.copyToOtherPane() }
            key("Move", shortcut: "F6", alt: "⇧⌘M") { state.moveToOtherPane() }
            key("New Folder", shortcut: "F7", alt: "⇧⌘N") { state.sheet = .newFolder }
            key("Delete", shortcut: "F8", alt: "⌘⌫") { state.requestTrash() }
            key("Peek", shortcut: "⌘Y") { state.peekArchive() }
                .disabled(state.archiveToPeek == nil)
                .help(state.archiveToPeek == nil
                      ? "Select one archive to look inside it"
                      : "Look inside \(state.archiveToPeek!.name) — ⌘Y")
            key("Link", shortcut: "⌘L") { state.linkActiveDirectory() }
            key("Path", shortcut: "⌥⌘P") { state.copySelectedNames() }
            key("Full", shortcut: "⌥⌘F") { state.copySelectedFullPaths() }
            Divider().frame(height: 16)
            key("Undo", shortcut: "⌘Z") { state.undoLast() }
                .disabled(!state.canUndo)
                .help(state.canUndo ? "Undo \(state.undoLabel) — ⌘Z" : "Nothing to undo")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) {
            Text("Tab switches panes")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Word only — the shortcuts live in the tooltip and the menus, so the row
    /// stays narrow enough to fit even at the smallest window size.
    private func key(
        _ title: String,
        shortcut: String,
        alt: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(alt.map { "\(title) — \(shortcut) or \($0)" } ?? "\(title) — \(shortcut)")
    }
}

struct TransferBar: View {
    let progress: TransferProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: progress.fraction)
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 1) {
                Text(progress.title).font(.system(size: 11, weight: .medium))
                Text(progress.current)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(progress.completed) / \(progress.total)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
