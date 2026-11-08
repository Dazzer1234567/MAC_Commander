import AppKit
import SwiftUI

/// What the user asked for when Find files closed.
enum SearchOutcome {
    case goTo(URL)
    case feed([URL])
}

/// Find files, after Total Commander's: masks, where to look, text within the file, and the
/// size and date limits on the Advanced tab. Results arrive as they are found, and can be
/// jumped to one at a time or fed into the pane as a flat list.
struct SearchSheet: View {
    let startFolder: String
    let onClose: (SearchOutcome?) -> Void

    @Environment(\.ui) private var ui
    @EnvironmentObject private var state: AppState
    @StateObject private var run = SearchRun()

    private enum Tab { case general, advanced }
    @State private var tab = Tab.general

    @State private var masks = SearchMemory.last.masks
    @State private var where_ = ""
    @State private var recursive = SearchMemory.last.recursive
    @State private var includeHidden = SearchMemory.last.includeHidden

    @State private var findText = !SearchMemory.last.text.isEmpty
    @State private var text = SearchMemory.last.text
    @State private var caseSensitive = SearchMemory.last.caseSensitive
    @State private var wholeWords = SearchMemory.last.wholeWords
    @State private var useRegex = SearchMemory.last.useRegex
    @State private var notContaining = SearchMemory.last.notContaining
    @State private var textFocus = 0

    @State private var sizeOn = false
    @State private var sizeRule = 0
    @State private var sizeText = "0"
    @State private var sizeUnit = 1
    @State private var afterOn = false
    @State private var after = Date()
    @State private var beforeOn = false
    @State private var before = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabStrip
            Group {
                switch tab {
                case .general: general
                case .advanced: advanced
                }
            }
            .padding(.top, ui.s(12))
            .frame(height: ui.s(236), alignment: .top)

            SearchResultsTable(run: run, version: run.version,
                               onActivate: goTo, onCancel: close)
                .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
                .padding(.top, ui.s(14))

            Text(run.status)
                .font(ui.font(12)).foregroundStyle(ui.dim)
                .lineLimit(1).truncationMode(.middle)
                .padding(.top, ui.s(8)).padding(.leading, ui.s(2))

            actions.padding(.top, ui.s(12))
        }
        .padding(ui.s(12))
        .frame(width: ui.s(900), height: ui.s(700))
        .background(ui.window)
        .onAppear { if where_.isEmpty { where_ = SearchMemory.last.where.isEmpty ? startFolder : SearchMemory.last.where } }
        // Closing the sheet any way at all stops a search still running.
        .onDisappear { run.stop() }
    }

    // MARK: - What to look for

    private var tabStrip: some View {
        HStack(spacing: 0) {
            tabButton("General", .general)
            tabButton("Advanced", .advanced)
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(ui.border).frame(height: 1) }
    }

    private func tabButton(_ title: String, _ which: Tab) -> some View {
        Button { tab = which } label: {
            Text(title)
                .font(ui.font(12, tab == which ? .semibold : .regular))
                .foregroundStyle(tab == which ? ui.text : ui.dim)
                .padding(.horizontal, ui.s(14)).padding(.vertical, ui.s(6))
                .background(tab == which ? ui.header : Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(tab == which ? ui.accent : Color.clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var general: some View {
        Grid(alignment: .leading, horizontalSpacing: ui.s(10), verticalSpacing: 0) {
            GridRow {
                label("Search for")
                field($masks, selectAll: true)
                Color.clear.frame(width: ui.s(100), height: 1)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text("*.cs;*.xaml finds either.  A plain word finds names containing it.  | excludes: *.* | *.bak")
                    .font(ui.font(11)).foregroundStyle(ui.dim)
                    .padding(.top, ui.s(4))
            }
            gap(12)
            GridRow {
                label("Search in")
                field($where_)
                Button("Browse…", action: browse)
                    .buttonStyle(DazButtonStyle())
                    .frame(width: ui.s(100))
            }
            gap(10)
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                HStack(spacing: ui.s(20)) {
                    check("Search subdirectories", $recursive)
                    check("Include hidden files", $includeHidden)
                }
            }
            gap(16)
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    check("Find text in the file", $findText)
                        .onChange(of: findText) { _, on in if on { textFocus += 1 } }
                    field($text, focusTrigger: textFocus)
                        .padding(.top, ui.s(6))
                        .disabled(!findText).allowsHitTesting(findText).opacity(findText ? 1 : 0.45)
                    HStack(spacing: ui.s(18)) {
                        check("Case sensitive", $caseSensitive)
                        check("Whole words only", $wholeWords)
                        check("Regular expression", $useRegex)
                        check("Find files NOT containing the text", $notContaining)
                    }
                    .padding(.top, ui.s(8))
                    .disabled(!findText)
                }
            }
        }
    }

    /// Space between grid rows. A modifier on a GridRow would stop it being a row, so the
    /// gaps are rows of their own.
    private func gap(_ height: CGFloat) -> some View {
        GridRow { Color.clear.frame(width: 1, height: ui.s(height)) }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ui.s(8)) {
                check("File size is", $sizeOn).frame(width: ui.s(130), alignment: .leading)
                Group {
                    menu($sizeRule, ["at least", "at most", "exactly"]).frame(width: ui.s(130))
                    field($sizeText).frame(width: ui.s(110))
                    menu($sizeUnit, ["bytes", "KB", "MB", "GB"]).frame(width: ui.s(90))
                }
                .disabled(!sizeOn)
            }
            HStack(spacing: ui.s(8)) {
                check("Changed after", $afterOn).frame(width: ui.s(130), alignment: .leading)
                datePicker($after).disabled(!afterOn)
            }
            .padding(.top, ui.s(12))
            HStack(spacing: ui.s(8)) {
                check("Changed before", $beforeOn).frame(width: ui.s(130), alignment: .leading)
                datePicker($before).disabled(!beforeOn)
            }
            .padding(.top, ui.s(8))
            Text("Dates are compared against the time the file was last written.")
                .font(ui.font(11)).foregroundStyle(ui.dim)
                .padding(.top, ui.s(16))
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: ui.s(8)) {
            Button("Start search", action: start)
                .buttonStyle(DazButtonStyle()).frame(width: ui.s(130))
                .disabled(run.running)
            Button("Stop") { run.stop() }
                .buttonStyle(DazButtonStyle()).frame(width: ui.s(90))
                .disabled(!run.running)
            Spacer()
            Button("Feed to listbox") { onClose(.feed(run.results.map(\.url))) }
                .buttonStyle(DazButtonStyle()).frame(width: ui.s(140))
                .disabled(run.running || run.results.isEmpty)
                .help("Show every result in the active pane as one flat list")
            Button("Go to file", action: goTo)
                .buttonStyle(DazButtonStyle()).frame(width: ui.s(110))
                .disabled(run.selected == nil)
            Button("Close", action: close)
                .buttonStyle(DazButtonStyle()).frame(width: ui.s(100))
                .keyboardShortcut(.cancelAction)
        }
    }

    private func start() {
        guard !run.running else { return }
        let criteria = gather()
        if criteria.roots.isEmpty {
            state.warn("Say which folder to search in.")
            return
        }
        run.start(criteria)
    }

    private func goTo() {
        guard let hit = run.selected else { return }
        run.stop()
        onClose(.goTo(hit.url))
    }

    private func close() {
        run.stop()
        onClose(nil)
    }

    private func browse() {
        let first = where_.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let panel = NSOpenPanel()
        panel.title = "Search in"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: first, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = URL(fileURLWithPath: first, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url { where_ = url.path }
    }

    private func gather() -> SearchCriteria {
        var c = SearchCriteria()
        c.masks = masks.trimmingCharacters(in: .whitespaces)
        c.where = where_.trimmingCharacters(in: .whitespaces)
        c.recursive = recursive
        c.includeHidden = includeHidden
        c.text = findText ? text : ""
        c.caseSensitive = caseSensitive
        c.wholeWords = wholeWords
        c.useRegex = useRegex
        c.notContaining = notContaining

        if sizeOn, let size = Int64(sizeText.trimmingCharacters(in: .whitespaces)) {
            c.sizeRule = [SizeComparison.atLeast, .atMost, .exactly][sizeRule]
            c.sizeBytes = size * ([1, 1024, 1024 * 1024, 1024 * 1024 * 1024] as [Int64])[sizeUnit]
        }

        let calendar = Calendar.current
        if afterOn { c.modifiedAfter = calendar.startOfDay(for: after) }

        // "before" means the whole of that day counts, not midnight at the start of it.
        if beforeOn, let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: before)) {
            c.modifiedBefore = next.addingTimeInterval(-0.001)
        }
        return c
    }

    // MARK: - Pieces

    private func label(_ title: String) -> some View {
        Text(title).font(ui.font(12)).foregroundStyle(ui.dim)
    }

    private func field(_ binding: Binding<String>, selectAll: Bool = false, focusTrigger: Int = 0) -> some View {
        DazTextField(text: binding, font: ui.nsMono(12), textColor: ui.palette.text,
                     background: ui.palette.panel, selectAllOnAppear: selectAll,
                     focusTrigger: focusTrigger, onSubmit: start, onCancel: close)
            .frame(height: ui.s(24))
    }

    private func check(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
            .toggleStyle(.checkbox)
            .font(ui.font(12)).foregroundStyle(ui.text)
    }

    private func menu(_ selection: Binding<Int>, _ choices: [String]) -> some View {
        Picker("", selection: selection) {
            ForEach(choices.indices, id: \.self) { Text(choices[$0]).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .font(ui.font(12))
    }

    private func datePicker(_ date: Binding<Date>) -> some View {
        DatePicker("", selection: date, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.field)
            .font(ui.font(12))
            .frame(width: ui.s(160), alignment: .leading)
    }
}

/// The dialog reopens where it left off, as DAZ Commander's does.
@MainActor
enum SearchMemory {
    static var last = SearchCriteria()
}

// MARK: - Running

/// One search running on a background thread, and what it has found so far. The worker
/// drops hits into an inbox; a timer on the main thread empties it a few times a second,
/// so a search that matches thousands of files spends its time searching, not handing
/// rows over one at a time.
@MainActor
final class SearchRun: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Ready."
    /// Bumped whenever rows arrive or the list is cleared, so the table catches up.
    @Published private(set) var version = 0
    @Published var selectedRow: Int?

    private(set) var results: [SearchHit] = []
    /// Bumped when the list is cleared for a fresh search.
    private(set) var generation = 0

    private var cancel: SearchCancel?
    private var inbox: SearchInbox?
    private var timer: Timer?
    private var criteria = SearchCriteria()
    private var started = Date()

    var selected: SearchHit? {
        guard let row = selectedRow, results.indices.contains(row) else { return nil }
        return results[row]
    }

    func start(_ criteria: SearchCriteria) {
        guard !running else { return }
        results.removeAll()
        generation += 1
        version += 1
        selectedRow = nil
        running = true
        status = "Searching…"

        let cancel = SearchCancel()
        let inbox = SearchInbox()
        self.cancel = cancel
        self.inbox = inbox
        self.criteria = criteria
        started = Date()

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            FileSearch.run(criteria, cancel: cancel, scanning: { inbox.scanning($0) }, found: { inbox.add($0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Only if this is still the search on show: after a Stop the dialog
                    // has already moved on.
                    if let self, self.cancel === cancel { self.finish() }
                }
            }
        }
    }

    /// Stops at once as far as the dialog is concerned. The worker notices between one
    /// entry and the next, but listing one enormous or slow folder can keep it busy a
    /// while longer; it then winds down on its own and what it finds is dropped.
    func stop() {
        guard running, let cancel else { return }
        cancel.cancel()
        finish()
    }

    private func drain() {
        guard let inbox else { return }
        let (hits, folder) = inbox.take()
        if !hits.isEmpty {
            results.append(contentsOf: hits)
            version += 1
        }
        if running, let folder {
            status = "Searching \(folder)"
        }
    }

    private func finish() {
        drain()
        let stopped = cancel?.isCancelled == true
        timer?.invalidate()
        timer = nil
        inbox = nil
        cancel = nil
        running = false

        let found = FileItem.grouped.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        status = "\(found) found in \(seconds)s\(stopped ? ", stopped" : "")"
        SearchMemory.last = criteria
    }
}

/// Where the worker thread leaves what it finds until the main thread collects it.
private final class SearchInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [SearchHit] = []
    private var folder: String?

    func add(_ hit: SearchHit) {
        lock.lock(); pending.append(hit); lock.unlock()
    }

    func scanning(_ path: String) {
        lock.lock(); folder = path; lock.unlock()
    }

    func take() -> ([SearchHit], String?) {
        lock.lock(); defer { lock.unlock() }
        let hits = pending
        let path = folder
        pending.removeAll(keepingCapacity: true)
        folder = nil
        return (hits, path)
    }
}

// MARK: - Results list

/// The results, drawn like a pane's file list. A table rather than a SwiftUI list, so
/// hundreds of thousands of rows stay quick and rows can be appended without redrawing
/// the lot. Double-click or Return goes to the file; Escape closes.
struct SearchResultsTable: NSViewRepresentable {
    @ObservedObject var run: SearchRun
    /// Passed in so a change of rows always reaches `updateNSView`.
    let version: Int
    let onActivate: () -> Void
    let onCancel: () -> Void

    @Environment(\.ui) private var ui

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("name", "Name", 260), ("size", "Size", 100), ("date", "Date", 150), ("folder", "Folder", 360),
    ]

    func makeCoordinator() -> Coordinator { Coordinator(run: run) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsTable()
        table.headerView = FileHeaderView()
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.gridStyleMask = []
        table.focusRingType = .none
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))

        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.minWidth = 40
            tableColumn.headerCell = FileHeaderCell(textCell: column.title)
            if column.id == "size" { tableColumn.headerCell.alignment = .right }
            tableColumn.resizingMask = column.id == "folder" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(tableColumn)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.run = run
        c.onActivate = onActivate
        c.onCancel = onCancel
        if let table = c.table {
            table.onActivate = onActivate
            table.onCancel = onCancel
        }
        c.apply(ui: ui)
        c.sync()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var run: SearchRun
        weak var table: ResultsTable?
        var onActivate: () -> Void = {}
        var onCancel: () -> Void = {}
        var ui = UI()
        private var appliedUI: (Double, NSColor)?
        private var shownGeneration = -1
        private var shownCount = 0
        private var syncing = false

        init(run: SearchRun) { self.run = run }

        func apply(ui newUI: UI) {
            guard let table else { return }
            if let applied = appliedUI, applied.0 == newUI.scale, applied.1 == newUI.palette.text { return }
            ui = newUI
            appliedUI = (ui.scale, ui.palette.text)
            table.rowHeight = ui.s(20)
            table.backgroundColor = ui.palette.panel
            table.enclosingScrollView?.backgroundColor = ui.palette.panel
            table.palette = ui.palette
            for column in table.tableColumns {
                (column.headerCell as? FileHeaderCell)?.ui = ui
                if let base = SearchResultsTable.columns.first(where: { $0.id == column.identifier.rawValue }) {
                    column.width = ui.s(base.width)
                }
            }
            (table.headerView as? FileHeaderView)?.ui = ui
            table.headerView?.frame.size.height = ui.s(22)
            table.reloadData()
        }

        /// New search: start the table afresh. Same search: only tell it about the rows
        /// added at the end, which costs nothing however long the list already is.
        func sync() {
            guard let table else { return }
            syncing = true
            defer { syncing = false }
            if run.generation != shownGeneration {
                shownGeneration = run.generation
                shownCount = run.results.count
                table.reloadData()
                table.deselectAll(nil)
            } else if run.results.count != shownCount {
                shownCount = run.results.count
                table.noteNumberOfRowsChanged()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { min(shownCount, run.results.count) }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = (tableView.makeView(withIdentifier: ResultRowView.id, owner: nil) as? ResultRowView) ?? ResultRowView()
            view.identifier = ResultRowView.id
            view.table = table
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, run.results.indices.contains(row) else { return nil }
            let hit = run.results[row]
            let id = column.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileCell) ?? FileCell(identifier: id)
            // A row like the pane's, for its size and date text and its icon.
            let item = FileItem(path: hit.path, name: hit.name, isDirectory: false, size: hit.size, modified: hit.modified)
            let color = ui.palette.text
            switch id.rawValue {
            case "name":
                cell.configure(text: hit.name, font: ui.nsFont(12), color: color,
                               icon: item.icon(cheap: true), ui: ui, alignment: .left)
            case "size":
                cell.configure(text: item.sizeText, font: ui.nsFont(12), color: color, ui: ui, alignment: .right)
            case "date":
                cell.configure(text: item.dateText, font: ui.nsFont(12), color: color, ui: ui, alignment: .left)
            default:
                cell.configure(text: hit.folder, font: ui.nsFont(12), color: ui.palette.textDim, ui: ui, alignment: .left)
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            let row = table.selectedRow
            let selected = row >= 0 ? row : nil
            if run.selectedRow != selected { run.selectedRow = selected }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            onActivate()
        }
    }
}

/// Return goes to the selected file and Escape closes, as in the pane.
final class ResultsTable: NSTableView {
    var onActivate: () -> Void = {}
    var onCancel: () -> Void = {}
    var palette = Palette.dark

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:      // Return, Enter
            if selectedRow >= 0 { onActivate() }
        case 53:          // Escape
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // the selected row is drawn brighter while the list has the keyboard
        if became { enumerateAvailableRowViews { view, _ in view.needsDisplay = true } }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { enumerateAvailableRowViews { view, _ in view.needsDisplay = true } }
        return resigned
    }
}

/// The pane's cursor colours for the selected row, the panel colour for the rest.
final class ResultRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("ResultRow")
    weak var table: ResultsTable?

    override func drawBackground(in dirtyRect: NSRect) {
        (table?.palette.panel ?? .clear).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let table else { return }
        let focused = table.window?.firstResponder === table
        (focused ? table.palette.cursor : table.palette.cursorInactive).setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool { get { false } set {} }
}
