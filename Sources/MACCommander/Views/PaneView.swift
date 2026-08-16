import SwiftUI

struct PaneView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var state: AppState
    let side: Side
    @FocusState.Binding var focusedSide: Side?

    @FocusState private var filterFieldFocused: Bool
    @State private var isDropTarget = false

    /// A pale blue that keeps the row text legible, rather than the saturated
    /// system selection colour.
    static let selectionTint = Color(
        nsColor: NSColor(calibratedRed: 0.72, green: 0.85, blue: 0.98, alpha: 1.0)
    )

    private var isActive: Bool { state.activeSide == side }

    /// Marked rows are red; everything else keeps its normal colour.
    private func textColor(for item: FileItem, dim: Bool) -> Color {
        if pane.marked.contains(item.url) { return .red }
        return dim ? .secondary : .primary
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if pane.filterVisible {
                filterBar
                Divider()
            }
            fileTable
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(
            PaneClickWatcher(onClickInside: { clickedRow in
                // Only step in for the inactive pane. In the active pane the
                // table already handles clicks correctly, and interfering would
                // break range- and drag-selection.
                guard focusedSide != side else { return }
                focusedSide = side
                let rows = pane.items
                if let clickedRow, clickedRow < rows.count {
                    pane.selection = [rows[clickedRow].url]
                    PaneClickWatcher.WatcherView.log("selected \(rows[clickedRow].name)")
                } else {
                    PaneClickWatcher.WatcherView.log("no row resolved (row=\(String(describing: clickedRow)), items=\(rows.count))")
                }
            }, onShiftClick: { row in
                focusedSide = side
                pane.markRange(toRowAt: row)
            }, isActive: isActive,
               onToggleMark: { pane.toggleMark() },
               onGoUp: { pane.goUp() })
        )
        .overlay {
            Rectangle()
                .strokeBorder(Color.orange, lineWidth: 2)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onChange(of: pane.filterVisible) { _, visible in
            if visible { filterFieldFocused = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            navButton("chevron.right", help: "Forward", enabled: pane.canGoForward, action: pane.goForward)

            bookmarkMenu

            breadcrumb

            Spacer(minLength: 0)

            Button {
                pane.filterVisible.toggle()
                if !pane.filterVisible { pane.filter = "" }
            } label: {
                Image(systemName: pane.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Filter this folder")

            backButton
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Color.orange.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { focusedSide = side }
    }

    /// The one back control, and deliberately the loudest thing in the header.
    /// It always climbs exactly one level and goes inert at the root — no
    /// history involved, so it can never bounce between two folders.
    private var backButton: some View {
        Button(action: pane.goUp) {
            Image(systemName: "arrowshape.left.fill")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(pane.canGoUp ? Color.red : Color.red.opacity(0.25))
                .frame(width: 40, height: 30)
                .contentShape(Rectangle())
        }
        .disabled(!pane.canGoUp)
        .help(pane.canGoUp ? "Up to \(pane.directory.deletingLastPathComponent().lastPathComponent)" : "Already at the top level")
    }

    private func navButton(
        _ symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .help(help)
    }

    private var bookmarkMenu: some View {
        Menu {
            ForEach(state.bookmarks.items) { bookmark in
                Button(bookmark.name) { pane.navigate(to: bookmark.url) }
            }
            Divider()
            Button("Add “\(pane.directory.lastPathComponent)”") { state.bookmarks.add(pane.directory) }
            Button("Manage Bookmarks…") { state.sheet = .manageBookmarks }
        } label: {
            Image(systemName: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bookmarks")
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(pane.ancestry, id: \.self) { url in
                    Button(url.path == "/" ? "Macintosh HD" : url.lastPathComponent) {
                        pane.navigate(to: url)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(url == pane.directory ? Color.primary : Color.secondary)
                    .fontWeight(url == pane.directory ? .semibold : .regular)
                    if url != pane.directory {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 2)
        }
        .defaultScrollAnchor(.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $pane.filter)
                .textFieldStyle(.plain)
                .focused($filterFieldFocused)
                .onSubmit { focusedSide = side }
            if !pane.filter.isEmpty {
                Button { pane.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button("Done") {
                pane.filterVisible = false
                pane.filter = ""
                focusedSide = side
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onExitCommand {
            pane.filterVisible = false
            pane.filter = ""
            focusedSide = side
        }
    }

    // MARK: - Table

    private var fileTable: some View {
        Table(pane.items, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 5) {
                    Image(nsImage: item.icon)
                    Text(item.name)
                        .foregroundStyle(textColor(for: item, dim: item.isHidden))
                        .fontWeight(pane.marked.contains(item.url) ? .semibold : .regular)
                        .italic(item.isSymlink)
                    Spacer(minLength: 0)
                }
                .rowHighlight(selected: pane.selection.contains(item.url))
            }
            .width(min: 140, ideal: 260)

            TableColumn("Size", value: \.size) { item in
                Text(item.displaySize)
                    .foregroundStyle(textColor(for: item, dim: true))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .rowHighlight(selected: pane.selection.contains(item.url))
            }
            .width(min: 60, ideal: 80, max: 140)

            TableColumn("Modified", value: \.modified) { item in
                Text(item.displayDate)
                    .foregroundStyle(textColor(for: item, dim: true))
                    .monospacedDigit()
                    .rowHighlight(selected: pane.selection.contains(item.url))
            }
            .width(min: 110, ideal: 140, max: 200)
        }
        .font(.system(size: 12))
        .tableStyle(.inset)
        .focused($focusedSide, equals: side)
        .contextMenu(forSelectionType: URL.self) { urls in
            rowMenu(for: urls)
        } primaryAction: { urls in
            focusedSide = side
            pane.open(Array(urls))
        }
        .onKeyPress(.return) {
            pane.open(Array(pane.selection))
            return .handled
        }
        .onKeyPress(.tab) {
            focusedSide = side.other
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            state.handleDrop(urls, into: side)
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let error = pane.loadError {
                ContentUnavailableView("Can’t read this folder", systemImage: "lock", description: Text(error))
            } else if pane.items.isEmpty {
                ContentUnavailableView(
                    pane.filter.isEmpty ? "Empty folder" : "No matches",
                    systemImage: pane.filter.isEmpty ? "folder" : "magnifyingglass"
                )
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for urls: Set<URL>) -> some View {
        if urls.isEmpty {
            Button("New Folder…") {
                focusedSide = side
                state.sheet = .newFolder
            }
            Button("Paste Path from Clipboard") {
                focusedSide = side
                if let text = NSPasteboard.general.string(forType: .string) {
                    pane.navigate(to: URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
                }
            }
        } else {
            Button("Open") { pane.open(Array(urls)) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
            }
            Divider()
            Button("Copy to Other Pane") {
                focusedSide = side
                state.copyToOtherPane()
            }
            Button("Move to Other Pane") {
                focusedSide = side
                state.moveToOtherPane()
            }
            Divider()
            Button("Rename…") {
                focusedSide = side
                state.requestRename()
            }
            Button("Copy Name") {
                focusedSide = side
                state.copySelectedNames()
            }
            Button("Copy Full Path") {
                focusedSide = side
                state.copySelectedFullPaths()
            }
            Divider()
            Button("Move to Trash") {
                focusedSide = side
                state.requestTrash()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(pane.items.count) item\(pane.items.count == 1 ? "" : "s")")
            if !pane.marked.isEmpty {
                Text("·")
                Text("\(pane.marked.count) marked")
                    .foregroundStyle(Color.red)
                if pane.markedSize > 0 {
                    Text("(\(ByteCountFormatter.string(fromByteCount: pane.markedSize, countStyle: .file)))")
                }
            } else if !pane.selection.isEmpty {
                Text("·")
                Text("\(pane.selection.count) under cursor")
                    .foregroundStyle(Color.orange)
            }
            Spacer()
            if pane.showHidden {
                Image(systemName: "eye").help("Hidden files are shown")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}



private extension View {
    /// Each cell paints its own slice of the selection band, because AppKit's
    /// row-level highlight is switched off in `PaneClickWatcher`.
    ///
    /// The band is drawn as a `.background`, which does not take part in sizing,
    /// so making it deliberately taller than any row cannot stretch the row the
    /// way negative padding did. The table clips the overflow, leaving a fill
    /// the full height of the line.
    func rowHighlight(selected: Bool) -> some View {
        // The gap between columns now lives inside the cell rather than between
        // cells, so the values keep their breathing room while the band behind
        // them still runs edge to edge.
        padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .center) {
                if selected {
                    // Height overflows deliberately and is clipped back to the
                    // row. Width must NOT overflow: a neighbouring cell's band
                    // is composited over this one and would hide its text.
                    PaneView.selectionTint.frame(height: 400)
                }
            }
    }
}
