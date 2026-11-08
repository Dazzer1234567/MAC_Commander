import AppKit
import SwiftUI

/// One pane's file list: an AppKit table driven entirely by `PaneModel`, with Total
/// Commander's keyboard and mouse model.
///
/// AppKit rather than SwiftUI's `Table`: the cursor and the marks are separate things here,
/// typing filters, right-click marks, a slow second click renames - none of which a SwiftUI
/// table will let go of its own selection behaviour for.
struct FileListView: NSViewRepresentable {
    @ObservedObject var pane: PaneModel
    @ObservedObject var state: AppState
    let ui: UI

    func makeCoordinator() -> Coordinator { Coordinator(pane: pane, state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.coordinator = context.coordinator
        table.headerView = FileHeaderView()
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.gridStyleMask = []
        table.focusRingType = .none
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)

        for (id, title, width) in [("name", "Name", 300.0), ("ext", "Ext", 60.0), ("size", "Size", 95.0),
                                   ("date", "Date", 135.0), ("attr", "Attr", 55.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 120 : 30
            column.headerCell = FileHeaderCell(textCell: title)
            if id == "size" { column.headerCell.alignment = .right }
            column.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        context.coordinator.table = table
        context.coordinator.apply(ui: ui, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.pane = pane
        c.state = state
        c.apply(ui: ui, force: false)
        c.sync()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var pane: PaneModel
        var state: AppState
        weak var table: FileTable?
        var ui = UI()
        private(set) var rows: [FileItem] = []
        private var shownVersion = -1
        private var shownActive: Bool?
        private var shownFocus = -1
        private var shownEditing: PaneModel.RenameRequest?
        private var settingSelection = false
        var hoverRow = -1
        var dropRow = -1

        init(pane: PaneModel, state: AppState) {
            self.pane = pane
            self.state = state
        }

        var isActive: Bool { state.activeSide == pane.side }

        func apply(ui newUI: UI, force: Bool) {
            guard let table else { return }
            let changed = force || newUI.scale != ui.scale || newUI.palette.text != ui.palette.text
            ui = newUI
            guard changed else { return }
            table.rowHeight = ui.s(20)
            table.backgroundColor = ui.palette.panel
            table.enclosingScrollView?.backgroundColor = ui.palette.panel
            for column in table.tableColumns {
                (column.headerCell as? FileHeaderCell)?.ui = ui
                let base: [String: CGFloat] = ["name": 300, "ext": 60, "size": 95, "date": 135, "attr": 55]
                if column.identifier.rawValue != "name", let width = base[column.identifier.rawValue] {
                    column.width = ui.s(width)
                }
            }
            (table.headerView as? FileHeaderView)?.ui = ui
            table.headerView?.frame.size.height = ui.s(22)
            table.sizeLastColumnToFit()
            shownVersion = -1
        }

        /// Brings the table in line with the model: rows, cursor, focus, the rename editor.
        func sync() {
            guard let table else { return }
            let active = isActive
            if pane.version != shownVersion || active != shownActive {
                shownVersion = pane.version
                shownActive = active
                rows = pane.visible
                updateSortIndicator()
                table.reloadData()
            }
            selectCursor()
            if pane.focusRequest != shownFocus {
                shownFocus = pane.focusRequest
                if active, !pane.scratchpadVisible, pane.editing == nil {
                    DispatchQueue.main.async { [weak table] in
                        guard let table, let window = table.window else { return }
                        if window.firstResponder !== table { window.makeFirstResponder(table) }
                    }
                }
                if let index = pane.cursorIndex { table.scrollRowToVisible(index) }
            }
            if pane.editing != shownEditing {
                shownEditing = pane.editing
                if let request = pane.editing { table.beginEditing(request) } else { table.endEditing() }
            }
        }

        private func selectCursor() {
            guard let table else { return }
            let index = pane.cursorID.flatMap { id in rows.firstIndex { $0.id == id } }
            let current = table.selectedRow
            if index != (current >= 0 ? current : nil) {
                settingSelection = true
                if let index { table.selectRowIndexes([index], byExtendingSelection: false) }
                else { table.deselectAll(nil) }
                settingSelection = false
            }
        }

        private func updateSortIndicator() {
            guard let table else { return }
            for column in table.tableColumns {
                let id = column.identifier.rawValue
                let matches = id == pane.sortColumn.rawValue
                table.setIndicatorImage(matches ? NSImage(named: pane.sortDescending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator") : nil,
                                        in: column)
            }
        }

        func item(at row: Int) -> FileItem? { rows.indices.contains(row) ? rows[row] : nil }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = (tableView.makeView(withIdentifier: FileRowView.id, owner: nil) as? FileRowView) ?? FileRowView()
            view.identifier = FileRowView.id
            view.coordinator = self
            view.row = row
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, let item = item(at: row) else { return nil }
            let id = column.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileCell) ?? FileCell(identifier: id)
            let marked = pane.isMarked(item)
            let color = marked ? ui.palette.marked : ui.palette.text
            let cheap = rows.count > 2000 || item.path.hasPrefix("/Volumes/") && NetworkPlaces.serverOfMountRoot(pane.realFolder) != nil
            switch id.rawValue {
            case "name":
                cell.configure(text: item.displayName, font: ui.nsFont(12), color: color,
                               icon: item.isParent ? nil : item.icon(cheap: cheap), upArrow: item.isParent,
                               ui: ui, alignment: .left, italic: item.isSymlink)
            case "ext":
                cell.configure(text: item.ext, font: ui.nsFont(12), color: color, ui: ui, alignment: .left)
            case "size":
                cell.configure(text: item.sizeText, font: ui.nsFont(12), color: color, ui: ui, alignment: .right)
            case "date":
                cell.configure(text: item.dateText, font: ui.nsFont(12), color: color, ui: ui, alignment: .left)
            default:
                cell.configure(text: item.attrText, font: ui.nsMono(11.5), color: color, ui: ui, alignment: .left)
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !settingSelection, let table else { return }
            let row = table.selectedRow
            if let item = item(at: row), pane.cursorID != item.id { pane.cursorID = item.id }
        }

        func tableView(_ tableView: NSTableView, didClick column: NSTableColumn) {
            guard let sort = SortColumn(rawValue: column.identifier.rawValue) else { return }
            pane.activate()
            pane.sort(by: sort)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

        // MARK: Drag and drop

        /// Where a drop at this row would go: the folder row under the pointer, or the
        /// folder the pane shows. Nil where nothing can go, or where the files already are.
        func dropFolder(row: Int, paths: [String]) -> String? {
            guard let folder0 = pane.writableFolder else { return nil }
            var folder = folder0
            if let item = item(at: row), item.isDirectory, !item.isParent, !item.isVirtual { folder = item.path }
            // A folder dropped on itself, or into one of its own folders, would never end.
            if paths.contains(where: { Paths.same($0, folder) || folder.hasPrefix($0 + "/") }) { return nil }
            // Dropped back where they came from: nothing to do.
            if paths.allSatisfy({ Paths.same(($0 as NSString).deletingLastPathComponent, folder) }) { return nil }
            return folder
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { nil }
    }
}

// MARK: - Table

/// The table itself: keys and mouse, Total Commander style.
final class FileTable: NSTableView {
    weak var coordinator: FileListView.Coordinator?

    private var lastClickedID: String?
    private var lastClickAt = Date.distantPast
    private var dragOrigin: NSPoint?
    private var dragArmed = false
    private var markOnRelease: String?
    private var editor: RenameEditor?
    private var editorScroll: NSScrollView?
    private var tracking: NSTrackingArea?

    /// How long after the first click a second still counts as "rename this".
    private static let renameWindow: TimeInterval = 1.0

    private var pane: PaneModel? { coordinator?.pane }
    private var state: AppState? { coordinator?.state }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { pane?.activate() }
        return became
    }

    // MARK: Keys

    private enum Key {
        static let enter: UInt16 = 36, keypadEnter: UInt16 = 76, tab: UInt16 = 48
        static let space: UInt16 = 49, backspace: UInt16 = 51, escape: UInt16 = 53
        static let help: UInt16 = 114, forwardDelete: UInt16 = 117
        static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
        static let left: UInt16 = 123, right: UInt16 = 124
        static let keypadStar: UInt16 = 67, keypadPlus: UInt16 = 69, keypadMinus: UInt16 = 78
    }

    override func keyDown(with event: NSEvent) {
        guard let pane, let state else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let cmd = mods.contains(.command), opt = mods.contains(.option), shift = mods.contains(.shift)

        switch event.keyCode {
        case Key.enter where !cmd && !opt, Key.keypadEnter where !cmd && !opt:
            if let item = pane.cursorItem { pane.activate(item) }
            return
        case Key.tab where !cmd && !opt:
            state.toggleActiveSide()
            return
        case Key.backspace where !cmd:
            if !pane.filter.isEmpty { pane.dropFilterCharacter() } else { pane.goUp() }
            return
        case Key.space where mods.isEmpty:
            if let item = pane.cursorItem { pane.toggleMark(item) }
            return
        case Key.help:
            if let item = pane.cursorItem { pane.toggleMark(item); pane.moveCursorDown() }
            return
        case Key.keypadStar:
            pane.invertMarks()
            return
        case Key.keypadPlus where !cmd:
            state.markByMask(on: true)
            return
        case Key.keypadMinus where !cmd:
            state.markByMask(on: false)
            return
        case Key.escape:
            // first press drops the filter, a second clears the marks
            if !pane.clearFilter() { pane.markAll(false) }
            return
        case Key.forwardDelete:
            state.doDelete(toTrash: !shift)
            return
        case Key.left where cmd, Key.right where cmd:
            state.targetEqualsSource()
            return
        case Key.home:
            moveCursor(to: 0)
            return
        case Key.end:
            moveCursor(to: numberOfRows - 1)
            return
        case Key.pageUp, Key.pageDown:
            let page = max(1, Int(visibleRect.height / rowHeight) - 1)
            let current = max(0, selectedRow)
            moveCursor(to: current + (event.keyCode == Key.pageUp ? -page : page))
            return
        default:
            break
        }

        // Letters typed into a list filter it to entries starting with them.
        if !cmd && !mods.contains(.control), let text = event.characters, !text.isEmpty,
           let scalar = text.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
           scalar.value < 0xF700 {
            pane.appendFilter(text)
            return
        }
        super.keyDown(with: event)
    }

    private func moveCursor(to row: Int) {
        guard numberOfRows > 0 else { return }
        let clamped = min(max(row, 0), numberOfRows - 1)
        selectRowIndexes([clamped], byExtendingSelection: false)
        scrollRowToVisible(clamped)
    }

    /// ⌘A arrives as Select All. In a file list that marks everything.
    override func selectAll(_ sender: Any?) {
        pane?.markAll(true)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let pane, let coordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let hit = coordinator.item(at: row)
        let anchor = pane.cursorID
        let wasCursor = hit != nil && hit?.id == anchor
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // The cursor moves before the pane is activated, so the click is never lost to
        // the activation: one click picks a row out of the other pane.
        if let hit { pane.cursorID = hit.id }
        window?.makeFirstResponder(self)
        pane.activate()

        // Any click in the list abandons an edit in progress.
        if pane.editing != nil { pane.cancelRename() }

        guard let clicked = hit else { return }

        if event.clickCount >= 2 && mods.isEmpty {
            dragArmed = false
            lastClickedID = nil
            pane.activate(clicked)
            return
        }

        // A second click on the row already under the cursor, slower than a double click
        // but within a second, means "rename".
        let now = Date()
        let since = now.timeIntervalSince(lastClickAt)
        let startsRename = lastClickedID == clicked.id && since > NSEvent.doubleClickInterval
            && since < FileTable.renameWindow && mods.isEmpty && !clicked.isParent
            && !pane.inArchive && !pane.inShareList && !pane.showingResults && wasCursor
        lastClickedID = clicked.id
        lastClickAt = now

        if startsRename {
            dragArmed = false
            pane.editing = PaneModel.RenameRequest(id: clicked.id, clickPoint: point)
            return
        }

        // Arm a possible drag: a plain one copies, a ⌘ one moves. Shift clicks are for
        // marking. Nothing inside an archive can be dragged: those paths are not on disk.
        dragOrigin = event.locationInWindow
        dragArmed = (mods.isEmpty || mods == .command) && !pane.inArchive && !pane.inShareList
        markOnRelease = nil

        if mods.contains(.command) {
            // marked when the button comes up, unless a drag starts first
            if dragArmed { markOnRelease = clicked.id } else { pane.toggleMark(clicked) }
        } else if mods.contains(.shift), let anchor {
            pane.markRange(from: anchor, to: clicked.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragArmed, let origin = dragOrigin, let pane else { return }
        let now = event.locationInWindow
        guard abs(now.x - origin.x) > 4 || abs(now.y - origin.y) > 4 else { return }
        dragArmed = false
        markOnRelease = nil

        let items = pane.actionItems.filter { !$0.isVirtual && !$0.isShare }
        guard !items.isEmpty else { return }
        let start = convert(origin, from: nil)
        var draggingItems: [NSDraggingItem] = []
        for (offset, item) in items.enumerated() {
            let dragging = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let icon = item.icon(cheap: true) ?? NSWorkspace.shared.icon(for: .data)
            let size = rowHeight
            dragging.setDraggingFrame(NSRect(x: start.x - size / 2, y: start.y - size / 2 + CGFloat(offset) * 3,
                                             width: size, height: size), contents: icon)
            draggingItems.append(dragging)
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragArmed = false
        // A ⌘-click that did not turn into a drag was a click after all: mark it now.
        if let id = markOnRelease, let pane, let item = pane.visible.first(where: { $0.id == id }) {
            pane.toggleMark(item)
        }
        markOnRelease = nil
    }

    /// Total Commander marks on right click rather than opening a menu.
    override func rightMouseDown(with event: NSEvent) {
        guard let pane, let coordinator else { return }
        window?.makeFirstResponder(self)
        pane.activate()
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard let item = coordinator.item(at: row) else { return }
        pane.cursorID = item.id
        pane.toggleMark(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// The mouse's thumb buttons: back goes up a level, forward goes into the highlighted
    /// folder - never launching a file, so a stray click cannot start a program.
    override func otherMouseDown(with event: NSEvent) {
        guard let pane else { return }
        switch event.buttonNumber {
        case 3:
            pane.activate()
            pane.goUp()
        case 4:
            pane.activate()
            pane.enterHighlightedDirectory()
        default:
            super.otherMouseDown(with: event)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { setHover(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(-1) }

    private func setHover(_ row: Int) {
        guard let coordinator, coordinator.hoverRow != row else { return }
        let old = coordinator.hoverRow
        coordinator.hoverRow = row
        for r in [old, row] where r >= 0 && r < numberOfRows { rowView(atRow: r, makeIfNecessary: false)?.needsDisplay = true }
    }

    // MARK: Dragging source

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic, .link]
    }

    // MARK: Dropping on the pane

    private func paths(from info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }

    private func dropTarget(_ info: NSDraggingInfo) -> (folder: String, row: Int)? {
        let paths = paths(from: info)
        guard !paths.isEmpty, let coordinator else { return nil }
        let row = self.row(at: convert(info.draggingLocation, from: nil))
        guard let folder = coordinator.dropFolder(row: row, paths: paths) else { return nil }
        let onRow = coordinator.item(at: row).map { $0.isDirectory && !$0.isParent && Paths.same($0.path, folder) } ?? false
        return (folder, onRow ? row : -1)
    }

    /// Copy, or move with ⌘ held at the drop.
    private func operation() -> NSDragOperation {
        NSEvent.modifierFlags.contains(.command) ? .move : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(sender)
        setDropRow(target?.row ?? -1)
        return target == nil ? [] : operation()
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropRow(-1) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropRow(-1)
        guard let target = dropTarget(sender), let state, let pane else { return false }
        let paths = paths(from: sender)
        let move = operation() == .move
        pane.activate()
        // Not done here and now: the drag is not over until this returns, and a copy can
        // take minutes.
        DispatchQueue.main.async { state.transferDropped(paths, into: target.folder, move: move) }
        return true
    }

    private func setDropRow(_ row: Int) {
        guard let coordinator, coordinator.dropRow != row else { return }
        let old = coordinator.dropRow
        coordinator.dropRow = row
        for r in [old, row] where r >= 0 && r < numberOfRows { rowView(atRow: r, makeIfNecessary: false)?.needsDisplay = true }
    }

    // MARK: Rename in place

    /// Opens the editor on a row with the name selected, less its extension. After a click
    /// the caret sits where the click landed as well: typing adds to the name there, while
    /// Delete clears what is selected.
    func beginEditing(_ request: PaneModel.RenameRequest) {
        endEditing()
        guard let coordinator, let row = coordinator.rows.firstIndex(where: { $0.id == request.id }) else { return }
        let item = coordinator.rows[row]
        scrollRowToVisible(row)
        let nameColumn = column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameColumn >= 0 else { return }
        var frame = frameOfCell(atColumn: nameColumn, row: row)
        let iconSpace = coordinator.ui.s(23)
        frame.origin.x += iconSpace
        frame.size.width -= iconSpace + 4

        let ui = coordinator.ui
        let scroll = NSScrollView(frame: frame)
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = ui.palette.panel

        let text = RenameEditor(frame: NSRect(origin: .zero, size: frame.size))
        text.isRichText = false
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = false
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: frame.height)
        text.textContainer?.lineFragmentPadding = 2
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: frame.height)
        text.font = ui.nsFont(12)
        text.textColor = ui.palette.text
        text.backgroundColor = ui.palette.panel
        text.insertionPointColor = ui.palette.text
        text.string = item.name
        text.delegate = self
        text.textContainerInset = NSSize(width: 0, height: max(0, (frame.height - (text.font?.boundingRectForFont.height ?? 14)) / 2))
        text.onCommit = { [weak self] in self?.commitEditing() }
        text.onCancel = { [weak self] in self?.pane?.cancelRename() }
        text.onLostFocus = { [weak self] in
            // Clicking away abandons the edit rather than applying it: only Enter renames.
            guard let self, self.editor != nil else { return }
            self.pane?.cancelRename()
        }
        scroll.documentView = text
        addSubview(scroll)
        editor = text
        editorScroll = scroll
        window?.makeFirstResponder(text)

        let stem = item.isDirectory || item.ext.isEmpty ? (item.name as NSString).length
            : max(0, (item.name as NSString).length - (item.ext as NSString).length - 1)
        text.setSelectedRange(NSRange(location: 0, length: stem))
        if let point = request.clickPoint {
            let local = text.convert(point, from: self)
            let index = text.characterIndexForInsertion(at: local)
            text.beginFresh(caret: min(index, (item.name as NSString).length), stemLength: stem)
        }
    }

    func endEditing() {
        guard let scroll = editorScroll else { return }
        editor = nil
        editorScroll = nil
        scroll.removeFromSuperview()
    }

    private func commitEditing() {
        guard let editor, let pane, let request = pane.editing,
              let item = pane.visible.first(where: { $0.id == request.id }) else { return }
        let typed = editor.string
        self.editor = nil
        if let done = pane.commitRename(item, to: typed) {
            state?.push(.rename(from: done.from, to: done.to))
        }
    }
}

/// The in-place rename editor. While the name is freshly selected after a click it also
/// shows a caret at the click point, and keys act there: typing inserts, Backspace rubs
/// out one character behind it, the arrows step from it, Delete clears the selection.
final class RenameEditor: NSTextView {
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onLostFocus: () -> Void = {}
    private var freshCaret: Int?
    private var freshLength = 0

    func beginFresh(caret: Int, stemLength: Int) {
        freshCaret = caret
        freshLength = stemLength
        needsDisplay = true
    }

    private func endFresh() {
        freshCaret = nil
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { self.onLostFocus() } }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: endFresh(); onCommit(); return
        case 53: endFresh(); onCancel(); return
        default: break
        }
        guard let at = freshCaret else { return super.keyDown(with: event) }
        let length = (string as NSString).length
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 117: // forward delete: clears the selected name
            endFresh()
            let cut = min(freshLength, length)
            if cut > 0 { replaceCharacters(in: NSRange(location: 0, length: cut), with: "") }
            setSelectedRange(NSRange(location: 0, length: 0))
        case 51: // backspace: one character behind the click point
            endFresh()
            var caret = min(at, length)
            if caret > 0 { replaceCharacters(in: NSRange(location: caret - 1, length: 1), with: ""); caret -= 1 }
            setSelectedRange(NSRange(location: caret, length: 0))
        case 123 where !shift, 124 where !shift:
            endFresh()
            let caret = event.keyCode == 123 ? max(0, min(at, length) - 1) : min(length, at + 1)
            setSelectedRange(NSRange(location: caret, length: 0))
        default:
            let chars = event.characters ?? ""
            if !chars.isEmpty, !event.modifierFlags.contains(.command),
               let scalar = chars.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
               scalar.value < 0xF700 {
                endFresh()
                let caret = min(at, length)
                replaceCharacters(in: NSRange(location: caret, length: 0), with: chars)
                setSelectedRange(NSRange(location: caret + (chars as NSString).length, length: 0))
                didChangeText()
            } else {
                endFresh()
                super.keyDown(with: event)
            }
        }
    }

    /// A paste adds to the name at the click point, the same as typing.
    override func paste(_ sender: Any?) {
        guard let at = freshCaret, let text = NSPasteboard.general.string(forType: .string) else {
            endFresh()
            return super.paste(sender)
        }
        endFresh()
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        let caret = min(at, (string as NSString).length)
        replaceCharacters(in: NSRange(location: caret, length: 0), with: clean)
        setSelectedRange(NSRange(location: caret + (clean as NSString).length, length: 0))
    }

    override func mouseDown(with event: NSEvent) {
        endFresh()
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let at = freshCaret, let layout = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        var x: CGFloat
        if at >= length {
            let glyphs = layout.glyphRange(for: container)
            x = layout.boundingRect(forGlyphRange: glyphs, in: container).maxX
        } else {
            let glyph = layout.glyphIndexForCharacter(at: at)
            x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
        }
        x += textContainerOrigin.x
        (insertionPointColor ?? .textColor).setFill()
        NSRect(x: x, y: textContainerOrigin.y + 1, width: 1.5, height: bounds.height - textContainerOrigin.y * 2 - 2).fill()
    }
}

// MARK: - Rows and cells

/// Draws a row's background. Three things want to colour a row, and they rank: the
/// cursor first, a mark second, hover last.
final class FileRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("FileRow")
    weak var coordinator: FileListView.Coordinator?
    var row = -1

    override func drawBackground(in dirtyRect: NSRect) {
        guard let coordinator else { return super.drawBackground(in: dirtyRect) }
        let palette = coordinator.ui.palette
        let item = coordinator.item(at: row)
        let isCursor = item?.id == coordinator.pane.cursorID && item != nil
        let marked = item.map { coordinator.pane.isMarked($0) } ?? false
        let color: NSColor
        if row == coordinator.dropRow { color = palette.accent.withAlphaComponent(0.45) }
        else if isCursor { color = coordinator.isActive ? palette.cursor : palette.cursorInactive }
        else if marked { color = palette.markedBg }
        else if row == coordinator.hoverRow { color = palette.hover }
        else { color = palette.panel }
        color.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

final class FileCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var iconWidth: NSLayoutConstraint?
    private var iconLead: NSLayoutConstraint?
    private var labelLead: NSLayoutConstraint?
    private var labelTrail: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.cell?.truncatesLastVisibleLine = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(label)
        iconLead = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 0)
        labelLead = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 0)
        labelTrail = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            iconLead!, iconWidth!, labelLead!, labelTrail!,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, font: NSFont, color: NSColor, icon image: NSImage? = nil, upArrow: Bool = false,
                   ui: UI, alignment: NSTextAlignment, italic: Bool = false) {
        label.stringValue = text
        label.font = italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        label.textColor = color
        label.alignment = alignment
        let isName = identifier?.rawValue == "name"
        if isName {
            if upArrow {
                let config = NSImage.SymbolConfiguration(pointSize: ui.s(12), weight: .bold)
                icon.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Up")?.withSymbolConfiguration(config)
                icon.contentTintColor = color
            } else {
                icon.image = image
                icon.contentTintColor = nil
            }
            iconWidth?.constant = ui.s(16)
            iconLead?.constant = ui.s(4)
            labelLead?.constant = ui.s(5)
        } else {
            icon.image = nil
            iconWidth?.constant = 0
            iconLead?.constant = 0
            labelLead?.constant = ui.s(5)
        }
        labelTrail?.constant = alignment == .right ? -ui.s(8) : -ui.s(4)
    }
}

/// Column headers drawn in the header colour, in the dim text colour, 11 points.
final class FileHeaderCell: NSTableHeaderCell {
    var ui = UI()

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        ui.palette.header.setFill()
        cellFrame.fill()
        ui.palette.border.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 3, width: 1, height: cellFrame.height - 6).fill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ui.nsFont(11), .foregroundColor: ui.palette.textDim,
        ]
        let text = NSAttributedString(string: stringValue, attributes: attributes)
        let size = text.size()
        let inset = ui.s(5)
        var rect = cellFrame.insetBy(dx: inset, dy: 0)
        rect.origin.y = cellFrame.midY - size.height / 2
        rect.size.height = size.height
        if alignment == .right { rect.origin.x = cellFrame.maxX - inset - size.width - ui.s(3) }
        text.draw(in: rect)
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        let arrow = ascending ? "▲" : "▼"
        let text = NSAttributedString(string: arrow, attributes: [.font: ui.nsFont(7), .foregroundColor: ui.palette.textDim])
        let size = text.size()
        text.draw(at: NSPoint(x: cellFrame.maxX - size.width - 3, y: cellFrame.midY - size.height / 2))
    }
}

final class FileHeaderView: NSTableHeaderView {
    var ui = UI()

    override func draw(_ dirtyRect: NSRect) {
        ui.palette.header.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}
