import AppKit
import Foundation

/// Watches a directory and fires a coalesced callback when its contents change. The
/// timer is not restarted by every event, so a file still growing - a download - shows
/// up while it is being written instead of only once it stops.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    let path: String

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        var pending = false
        source.setEventHandler {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pending = false
                onChange()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// Where a pane is pointed.
enum PaneLocation: Equatable {
    case folder(String)
    /// Inside an archive, browsed from its table of contents. inner == "" is its root.
    case archive(archive: String, inner: String)
    /// The folders another computer shares.
    case shares(server: String)
    /// Search results fed to the pane: entries from all over, no one folder.
    case results(String)

    /// What the path box shows. Inside an archive the archive's own path carries on into it.
    var displayPath: String {
        switch self {
        case .folder(let path): return path
        case .archive(let archive, let inner): return inner.isEmpty ? archive : archive + "/" + inner
        case .shares(let server): return "smb://" + server
        case .results(let text): return text
        }
    }
}

/// One pane: what it lists, the cursor, the marks, the typed filter, and its scratchpad.
@MainActor
final class PaneModel: ObservableObject {
    @Published private(set) var location: PaneLocation = .folder("/")
    /// Every row, sorted, ".." included.
    @Published private(set) var items: [FileItem] = []
    /// Typed prefix. While set, the list shows only entries starting with it.
    @Published private(set) var filter = ""
    /// Marked rows, by id. Independent of the cursor, Total Commander's model.
    @Published private(set) var marks: Set<String> = []
    /// The row under the cursor, by id.
    @Published var cursorID: String?
    @Published private(set) var sortColumn: SortColumn = .name
    @Published private(set) var sortDescending = false
    @Published var showHidden = false
    @Published private(set) var scratchpadVisible = false
    @Published var scratchpadText = ""
    /// Bumped whenever the rows change in a way the table has to redraw for.
    @Published private(set) var version = 0
    /// The row whose name is being edited in place, and where the click landed.
    @Published var editing: RenameRequest?
    /// Tells the table to scroll the cursor into view and take the keyboard.
    @Published var focusRequest = 0

    struct RenameRequest: Equatable {
        let id: String
        /// Where in the name the caret goes; nil selects the name without its extension.
        let clickPoint: NSPoint?
    }

    let side: Side
    /// Says why something could not be shown.
    var warn: (String) -> Void = { _ in }
    /// The pane wants to be the active one.
    var activate: () -> Void = {}
    /// The pane went somewhere else.
    var pathChanged: () -> Void = {}

    private var watcher: DirectoryWatcher?
    private var archiveIndex: ArchiveIndex?
    private var backStack: [PaneLocation] = []
    private var forwardStack: [PaneLocation] = []
    /// The Tailscale computers last found, for naming them.
    var computers: [NetworkComputer] = []

    init(side: Side) { self.side = side }

    // MARK: - Where the pane is

    var archive: (archive: String, inner: String)? {
        if case .archive(let a, let i) = location { return (a, i) }
        return nil
    }

    var inArchive: Bool { archive != nil }

    var inShareList: Bool {
        if case .shares = location { return true }
        return false
    }

    var showingResults: Bool {
        if case .results = location { return true }
        return false
    }

    /// The path the pane is at, as the path box shows it.
    var currentPath: String { location.displayPath }

    /// A folder that is really there: the pane's own, or the one its archive sits in.
    var realFolder: String {
        switch location {
        case .folder(let p): return p
        case .archive(let a, _): return (a as NSString).deletingLastPathComponent
        case .shares, .results: return Paths.home
        }
    }

    /// Somewhere new files can go, or nil where nothing can be made.
    var writableFolder: String? {
        if case .folder(let p) = location { return p }
        return nil
    }

    // MARK: - Rows

    /// Entries currently shown: everything, or what starts with the typed letters.
    /// ".." always stays so you can climb out of a filtered listing.
    var visible: [FileItem] {
        guard !filter.isEmpty else { return items }
        return items.filter { $0.isParent || $0.name.lowercased().hasPrefix(filter.lowercased()) }
    }

    var cursorItem: FileItem? {
        guard !scratchpadVisible, let cursorID else { return nil }
        return visible.first { $0.id == cursorID }
    }

    var cursorIndex: Int? {
        guard let cursorID else { return nil }
        return visible.firstIndex { $0.id == cursorID }
    }

    func isMarked(_ item: FileItem) -> Bool { marks.contains(item.id) }

    /// Marked entries, or the item under the cursor when nothing is marked. Never "..".
    /// Only what is on screen: acting on a marked row the filter has hidden would be a trap.
    var actionItems: [FileItem] {
        if scratchpadVisible { return [] }
        let marked = visible.filter { !$0.isParent && marks.contains($0.id) }
        if !marked.isEmpty { return marked }
        if let cursor = cursorItem, !cursor.isParent { return [cursor] }
        return []
    }

    // MARK: - Navigation

    /// Shows a folder, an archive, or a computer's shares. False means it could not be
    /// shown and the pane stayed put.
    @discardableResult
    func navigate(_ typed: String, focus: String? = nil, recordHistory: Bool = true) -> Bool {
        guard let target = resolve(typed) else { return false }
        return go(to: target, focus: focus, recordHistory: recordHistory)
    }

    /// Works out what a typed path names. Folders win over archives, so a folder called
    /// "something.zip" is a folder.
    func resolve(_ typed: String) -> PaneLocation? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if let server = NetworkPlaces.serverOnly(trimmed) { return .shares(server: server) }
        if let (server, share, rest) = NetworkPlaces.shareParts(trimmed) {
            // Not mounted yet: the mount runs in the background, with macOS asking for a
            // login if one is needed, and the pane goes there once it is up.
            guard let mounted = NetworkPlaces.reach(
                server: server, share: share, name: computerName(server), warn: warn,
                whenMounted: { [weak self] point in
                    self?.navigate(rest.isEmpty ? point : (point as NSString).appendingPathComponent(rest))
                })
            else { return nil }
            return .folder(rest.isEmpty ? mounted : (mounted as NSString).appendingPathComponent(rest))
        }
        let path = Paths.resolve(trimmed, relativeTo: realFolder)
        if Paths.isDirectory(path) { return .folder(path) }
        if let located = ArchiveService.locate(path) { return .archive(archive: located.archive, inner: located.inner) }
        warn("Directory not found:\n\(path)")
        return nil
    }

    func computerName(_ server: String) -> String {
        computers.first { $0.address.caseInsensitiveCompare(server) == .orderedSame }?.name ?? server
    }

    @discardableResult
    func go(to target: PaneLocation, focus: String? = nil, recordHistory: Bool = true) -> Bool {
        let listed: [FileItem]
        do {
            listed = try list(target)
        } catch {
            switch target {
            case .archive(let a, _):
                warn("Cannot read \((a as NSString).lastPathComponent):\n\(error.localizedDescription)")
            case .shares(let server):
                warn("Cannot open \(computerName(server)):\n\(error.localizedDescription)")
            default:
                warn("Cannot read directory:\n\(error.localizedDescription)")
            }
            return false
        }

        if recordHistory && target != location && !showingResults {
            backStack.append(location)
            if backStack.count > 50 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        if location.archiveFile != target.archiveFile { archiveIndex = nil }

        location = target
        var sorted = listed
        Listing.sort(&sorted, by: sortColumn, descending: sortDescending)
        items = sorted
        filter = ""
        marks = []
        editing = nil

        if case .folder(let path) = target { watch(path) } else { watcher = nil }

        selectByName(focus)
        version += 1
        pathChanged()
        return true
    }

    /// Reads a location's rows. Throws when it cannot be read.
    private func list(_ target: PaneLocation) throws -> [FileItem] {
        switch target {
        case .folder(let path):
            var rows: [FileItem] = []
            if path != "/" { rows.append(.parent((path as NSString).deletingLastPathComponent)) }
            let urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: FileItem.resourceKeys, options: [])
            for url in urls {
                guard let item = FileItem(url: url) else { continue }
                if !showHidden && item.isHidden { continue }
                rows.append(item)
            }
            return rows

        case .archive(let archive, let inner):
            let index = try (location.archiveFile == archive ? archiveIndex : nil) ?? ArchiveService.index(of: URL(fileURLWithPath: archive))
            archiveIndex = index
            guard index.containsDirectory(inner) else {
                throw ArchiveError.toolFailed("There is no folder \(inner) in it.")
            }
            let above = inner.isEmpty
                ? (archive as NSString).deletingLastPathComponent
                : archive + "/" + (inner as NSString).deletingLastPathComponent
            var rows: [FileItem] = [.parent(above)]
            for node in index.children(of: inner) {
                let item = FileItem(node: node, in: archive)
                if !showHidden && item.isHidden { continue }
                rows.append(item)
            }
            return rows

        case .shares(let server):
            let shares = try NetworkPlaces.listShares(server: server)
            return shares.map {
                FileItem(path: "smb://\(server)/\($0)", name: $0, isDirectory: true, isShare: true)
            }

        case .results:
            return items
        }
    }

    /// Shows search results in place of a folder listing, Total Commander's "feed to
    /// listbox". Refreshing or navigating puts the pane back on a real folder.
    func showResults(_ results: [URL]) {
        if !showingResults {
            backStack.append(location)
            forwardStack.removeAll()
        }
        watcher = nil
        let rows = results.compactMap { url -> FileItem? in
            guard let item = FileItem(url: url) else { return nil }
            // the name column shows where it is, since the rows come from all over
            return FileItem(path: item.path, name: item.name, isDirectory: item.isDirectory,
                            isPackage: item.isPackage, isSymlink: item.isSymlink, isHidden: item.isHidden,
                            isReadOnly: item.isReadOnly, isExecutable: item.isExecutable,
                            size: item.size, modified: item.modified, fromResults: true)
        }
        location = .results("Search results (\(rows.count))")
        items = rows
        filter = ""
        marks = []
        cursorID = rows.first?.id
        version += 1
        pathChanged()
    }

    /// Re-reads the location, keeping the cursor on the same entry where possible.
    func refresh(focus: String? = nil) {
        if showingResults, let previous = backStack.last {
            backStack.removeLast()
            go(to: previous, focus: focus, recordHistory: false)
            return
        }
        go(to: location, focus: focus ?? cursorID, recordHistory: false)
    }

    /// Brings the listing up to date with what is on disk. Unlike `refresh` it keeps marks,
    /// the typed filter and the cursor, since nobody asked for it.
    func resync() {
        guard editing == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resync() }
            return
        }
        switch location {
        case .archive(let a, _):
            if !FileManager.default.fileExists(atPath: a) { navigate(nearestFolder(a)) }
            return
        case .shares, .results:
            return
        case .folder(let path):
            guard Paths.isDirectory(path) else {
                navigate(nearestFolder(path))
                return
            }
            guard var fresh = try? list(location) else { return }
            Listing.sort(&fresh, by: sortColumn, descending: sortDescending)
            if fresh == items { return }

            let oldIndex = cursorIndex
            items = fresh
            marks.formIntersection(Set(fresh.map(\.id)))
            if let cursorID, !visible.contains(where: { $0.id == cursorID }) {
                let rows = visible
                self.cursorID = rows.isEmpty ? nil : rows[min(oldIndex ?? 0, rows.count - 1)].id
            }
            version += 1
        }
    }

    private func nearestFolder(_ path: String) -> String {
        var up = path
        while up != "/" && !Paths.isDirectory(up) { up = (up as NSString).deletingLastPathComponent }
        return up
    }

    private func watch(_ path: String) {
        if let watcher, watcher.path == path { return }
        watcher = DirectoryWatcher(path: path) { [weak self] in self?.resync() }
    }

    var canGoUp: Bool { parentLocation != nil }

    /// The location above this one. The top of an archive has its folder above it; the top
    /// of a mounted share has its computer's list of shares.
    private var parentLocation: (PaneLocation, String)? {
        switch location {
        case .folder(let path):
            if let server = NetworkPlaces.serverOfMountRoot(path) {
                return (.shares(server: server), (path as NSString).lastPathComponent)
            }
            guard path != "/" else { return nil }
            return (.folder((path as NSString).deletingLastPathComponent), (path as NSString).lastPathComponent)
        case .archive(let a, let inner):
            if inner.isEmpty {
                return (.folder((a as NSString).deletingLastPathComponent), (a as NSString).lastPathComponent)
            }
            return (.archive(archive: a, inner: (inner as NSString).deletingLastPathComponent),
                    (inner as NSString).lastPathComponent)
        case .shares, .results:
            return nil
        }
    }

    /// Up one level, landing the cursor on the folder just left, as Total Commander does.
    func goUp() {
        if showingResults { refresh(); return }
        guard let (target, name) = parentLocation else { return }
        go(to: target, focus: name)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        if !go(to: previous, recordHistory: false) { forwardStack.removeLast() }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        if !go(to: next, recordHistory: false) { backStack.removeLast() }
    }

    /// Enter, or a double-click: go into folders and archives, open anything else.
    func activate(_ item: FileItem) {
        if item.isParent { goUp(); return }
        if item.isShare {
            navigate(item.path)
            return
        }
        if item.isDirectory {
            switch location {
            case .archive(let a, _): go(to: .archive(archive: a, inner: item.archivePath ?? ""))
            default: go(to: .folder(item.path))
            }
            return
        }
        // A file inside an archive is not on disk to be opened, so a copy is put out for
        // the purpose. Changes made to that copy do not find their way back.
        var path = item.path
        if inArchive {
            guard let copy = readableCopy(of: item) else { return }
            path = copy
        }
        if ArchiveService.isArchive(URL(fileURLWithPath: path)) {
            go(to: .archive(archive: path, inner: ""))
            return
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            warn("Cannot open file:\n\(path)")
        }
    }

    /// Enters the folder under the cursor, or the archive. Driven by the mouse forward
    /// button, so it never launches a file.
    func enterHighlightedDirectory() {
        guard let item = cursorItem else { return }
        if item.isDirectory || item.isShare || (!item.isVirtual && ArchiveService.isArchive(item.url)) {
            activate(item)
        }
    }

    /// A path on disk for something that has to read the file under the cursor. Inside an
    /// archive that is a temporary copy, made now.
    func readableCursorFile() -> String? {
        guard let item = cursorItem, !item.isDirectory, !item.isParent else { return nil }
        return item.isVirtual ? readableCopy(of: item) : item.path
    }

    private func readableCopy(of item: FileItem) -> String? {
        guard let (archive, inner) = archive, let entry = item.archivePath else { return nil }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MACCommander-preview")
            .appendingPathComponent(UUID().uuidString)
        do {
            let depth = inner.isEmpty ? 0 : inner.split(separator: "/").count
            try ArchiveService.extractEntries([entry], from: URL(fileURLWithPath: archive), into: temp,
                                              strippingComponents: depth)
            return temp.appendingPathComponent(item.name).path
        } catch {
            warn("Cannot read \(item.name):\n\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Cursor

    func selectByName(_ name: String?) {
        let rows = visible
        if let name, let match = rows.first(where: { $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            cursorID = match.id
        } else {
            cursorID = (rows.first { !$0.isParent } ?? rows.first)?.id
        }
        focusRequest += 1
    }

    func moveCursorDown() {
        let rows = visible
        guard let index = cursorIndex, index < rows.count - 1 else { return }
        cursorID = rows[index + 1].id
        focusRequest += 1
    }

    // MARK: - Marking

    func toggleMark(_ item: FileItem) {
        guard !item.isParent else { return }
        if marks.contains(item.id) { marks.remove(item.id) } else { marks.insert(item.id) }
        version += 1
    }

    func markAll(_ on: Bool) {
        for item in visible where !item.isParent {
            if on { marks.insert(item.id) } else { marks.remove(item.id) }
        }
        version += 1
    }

    func invertMarks() {
        for item in visible where !item.isParent {
            if marks.contains(item.id) { marks.remove(item.id) } else { marks.insert(item.id) }
        }
        version += 1
    }

    /// Marks exactly the named entries, e.g. what a copy just put here.
    func markNames(_ names: [String]) {
        let wanted = Set(names.map { $0.lowercased() })
        marks = Set(visible.filter { !$0.isParent && wanted.contains($0.name.lowercased()) }.map(\.id))
        version += 1
    }

    /// Every row between two others, both ends included, in the order shown.
    func markRange(from: String, to: String) {
        let rows = visible
        guard let a = rows.firstIndex(where: { $0.id == from }),
              let b = rows.firstIndex(where: { $0.id == to }) else { return }
        for row in rows[min(a, b)...max(a, b)] where !row.isParent { marks.insert(row.id) }
        version += 1
    }

    /// Num +/-: mark or unmark files by wildcard. Folders are left alone, as in Total Commander.
    func mark(byMask mask: String, on: Bool) {
        guard let regex = Listing.maskRegex(mask == "*.*" ? "*" : mask) else { return }
        for item in visible where !item.isParent && !item.isDirectory {
            let range = NSRange(item.name.startIndex..., in: item.name)
            if regex.firstMatch(in: item.name, range: range) != nil {
                if on { marks.insert(item.id) } else { marks.remove(item.id) }
            }
        }
        version += 1
    }

    // MARK: - Type to filter

    /// Typing narrows to what starts with the letters, and the cursor goes to the most
    /// recently changed folder among them, so Enter goes straight in. With no folder left,
    /// the newest file.
    func appendFilter(_ text: String) {
        filter += text
        applyFilter()
    }

    func dropFilterCharacter() {
        guard !filter.isEmpty else { return }
        filter.removeLast()
        applyFilter()
    }

    /// Drops the filter. False when there was nothing to clear.
    @discardableResult
    func clearFilter() -> Bool {
        guard !filter.isEmpty else { return false }
        filter = ""
        applyFilter()
        return true
    }

    private func applyFilter() {
        let rows = visible
        if !filter.isEmpty {
            let newest: ([FileItem]) -> FileItem? = { $0.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) } }
            cursorID = (newest(rows.filter { $0.isDirectory && !$0.isParent })
                        ?? newest(rows.filter { !$0.isParent }) ?? rows.first)?.id
        } else if cursorID == nil || !rows.contains(where: { $0.id == cursorID }) {
            cursorID = (rows.first { !$0.isParent } ?? rows.first)?.id
        }
        version += 1
        focusRequest += 1
    }

    // MARK: - Sorting

    func sort(by column: SortColumn) {
        if sortColumn == column { sortDescending.toggle() } else { sortColumn = column; sortDescending = false }
        var sorted = items
        Listing.sort(&sorted, by: sortColumn, descending: sortDescending)
        items = sorted
        version += 1
        focusRequest += 1
    }

    // MARK: - Hidden files

    func setShowHidden(_ show: Bool) {
        showHidden = show
        refresh()
    }

    // MARK: - Rename in place

    /// Starts a rename from the keyboard, with the name selected but not the extension.
    func beginRename(clickPoint: NSPoint? = nil) {
        guard !inArchive, !inShareList, !showingResults,
              let item = cursorItem, !item.isParent else { return }
        editing = RenameRequest(id: item.id, clickPoint: clickPoint)
    }

    /// Applies a typed name. Only Enter gets here: clicking away abandons the edit.
    func commitRename(_ item: FileItem, to typed: String) -> (from: URL, to: URL)? {
        editing = nil
        let newName = typed.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.name else { focusRequest += 1; return nil }
        guard !newName.contains("/") else {
            warn("Cannot rename:\nA name cannot contain a slash.")
            focusRequest += 1
            return nil
        }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            // A change of case alone is a rename on a case-insensitive disk too.
            if newName.lowercased() != item.name.lowercased(),
               FileManager.default.fileExists(atPath: destination.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: item.url, to: destination)
            refresh(focus: newName)
            return (item.url, destination)
        } catch {
            warn("Cannot rename:\n\(error.localizedDescription)")
            refresh(focus: item.name)
            return nil
        }
    }

    func cancelRename() {
        guard editing != nil else { return }
        editing = nil
        focusRequest += 1
    }

    // MARK: - Scratchpad

    /// Swaps the listing for a plain-text editor and back. The text is kept.
    func showScratchpad(_ on: Bool) {
        scratchpadVisible = on
        filter = ""
        if !on { focusRequest += 1 }
    }

    // MARK: - Status

    var statusText: String {
        if scratchpadVisible {
            let lines = scratchpadText.isEmpty ? 1 : scratchpadText.components(separatedBy: "\n").count
            return "Scratchpad  —  \(Listing.plural(scratchpadText.count, "character")), "
                + "\(Listing.plural(lines, "line"))  (plain text, ISO 8859-1)"
        }
        if showingResults {
            return "\(Listing.plural(items.count, "search result"))  —  "
                + Listing.formatBytes(items.reduce(0) { $0 + $1.size })
        }
        let entries = visible.filter { !$0.isParent }
        let marked = entries.filter { marks.contains($0.id) }
        let files = entries.filter { !$0.isDirectory }
        let markedFiles = marked.filter { !$0.isDirectory }
        let suffix = filter.isEmpty ? "" : "   (filtered by \"\(filter)\")"
        return Listing.summarize(files: files.count, dirs: entries.count - files.count,
                                 totalBytes: files.reduce(0) { $0 + $1.size },
                                 markedFiles: markedFiles.count, markedDirs: marked.count - markedFiles.count,
                                 markedBytes: markedFiles.reduce(0) { $0 + $1.size }) + suffix
    }

    var freeSpaceText: String {
        guard case .folder(let path) = location,
              let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity
        else { return "" }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return "\(Listing.formatBytes(free)) free of \(Listing.formatBytes(Int64(total)))"
    }
}

extension PaneLocation {
    var archiveFile: String? {
        if case .archive(let a, _) = self { return a }
        return nil
    }
}
