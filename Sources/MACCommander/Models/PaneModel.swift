import Foundation
import SwiftUI

/// Watches a directory and fires a coalesced callback when its contents change,
/// so a copy landing in one pane shows up in the other without a manual refresh.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
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

/// Where a pane is pointed. Archives are browsed in place from their table of
/// contents rather than unpacked, so a location can be a real folder or a path
/// inside an archive.
enum PaneLocation: Equatable, Hashable {
    case folder(URL)
    case archive(archive: URL, inner: String)   // inner == "" is the archive root

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var archiveURL: URL? {
        if case .archive(let archive, _) = self { return archive }
        return nil
    }

    var isInsideArchive: Bool { archiveURL != nil }

    /// The real folder this location lives in — the folder itself, or the one
    /// holding the archive. Used for "reveal in Finder" and the like.
    var enclosingFolder: URL {
        switch self {
        case .folder(let url): return url
        case .archive(let archive, _): return archive.deletingLastPathComponent()
        }
    }

    var title: String {
        switch self {
        case .folder(let url): return url.lastPathComponent
        case .archive(let archive, let inner):
            return inner.isEmpty ? archive.lastPathComponent : String(inner.split(separator: "/").last ?? "")
        }
    }
}

@MainActor
final class PaneModel: ObservableObject {
    @Published private(set) var location: PaneLocation
    @Published private(set) var allItems: [FileItem] = []
    /// The cursor: the row (or rows) highlighted in blue. Moving it is not a
    /// selection in the Total Commander sense.
    @Published var selection: Set<URL> = []

    /// Items marked with the space bar, shown in red. These are what commands
    /// act on; the cursor is only a fallback when nothing is marked.
    @Published var marked: Set<URL> = []
    @Published var filter: String = ""
    @Published var filterVisible = false
    @Published var showHidden = false
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [.init(\.name, order: .forward)]
    @Published private(set) var loadError: String?

    private var backStack: [PaneLocation] = []
    private var forwardStack: [PaneLocation] = []
    private var watcher: DirectoryWatcher?
    private var archiveIndex: ArchiveIndex?

    init(directory: URL) {
        self.location = .folder(directory)
        reload()
        startWatching()
    }

    // MARK: - Where we are

    /// The folder new files can be written into. Nil inside an archive, which
    /// is what every write path checks before doing anything.
    var writableDirectory: URL? { location.folderURL }

    var isInsideArchive: Bool { location.isInsideArchive }

    /// Kept for the many callers that just want "the folder this pane relates
    /// to" — bookmarks, Reveal in Finder, Terminal Here.
    var directory: URL { location.enclosingFolder }

    // MARK: - Derived state

    /// Folders always sort above files, Finder-style; the column sort applies within each group.
    var items: [FileItem] {
        var list = allItems
        if !showHidden { list = list.filter { !$0.isHidden } }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        }
        list.sort(using: sortOrder)
        return list.filter(\.navigable) + list.filter { !$0.navigable }
    }

    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }

    var markedItems: [FileItem] { items.filter { marked.contains($0.url) } }

    /// What a command should act on: everything marked, or the row under the
    /// cursor when nothing is marked.
    var operationTargets: [FileItem] {
        marked.isEmpty ? selectedItems : markedItems
    }

    /// Space toggles the mark on whatever the cursor covers. Marking is
    /// all-or-nothing across the cursor so a repeated press always reverses the
    /// previous one.
    func toggleMark() {
        guard !selection.isEmpty else { return }
        if selection.isSubset(of: marked) {
            marked.subtract(selection)
        } else {
            marked.formUnion(selection)
        }
    }

    /// Shift-click: mark everything from the cursor down (or up) to the row
    /// clicked, and leave the cursor on that row. The anchor is wherever the
    /// cursor currently sits, so successive shift-clicks extend from the last
    /// one rather than from the original click.
    func markRange(toRowAt index: Int) {
        let rows = items
        guard rows.indices.contains(index) else { return }
        let anchorIndex = selection.count == 1
            ? (rows.firstIndex { selection.contains($0.url) } ?? index)
            : index
        let span = min(anchorIndex, index)...max(anchorIndex, index)
        marked.formUnion(rows[span].map(\.url))
        selection = [rows[index].url]
    }

    func unmarkAll() { marked = [] }

    func markAll() { marked = Set(items.map(\.url)) }

    func invertMarks() {
        marked = Set(items.map(\.url)).symmetricDifference(marked)
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + ($1.navigable ? 0 : $1.size) } }

    var markedSize: Int64 { markedItems.reduce(0) { $0 + ($1.navigable ? 0 : $1.size) } }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// One breadcrumb: what to show, and where clicking it goes.
    struct Crumb: Identifiable {
        let id: Int
        let label: String
        let target: PaneLocation
        let isArchive: Bool
    }

    /// The trail from `/` to here. Inside an archive it runs through the real
    /// folders, then the archive itself, then the path within it — so the bar
    /// reads as one continuous route rather than showing a synthetic path.
    var crumbs: [Crumb] {
        var folders: [URL] = []
        var url: URL = location.enclosingFolder
        while true {
            folders.append(url)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        folders.reverse()

        var result: [Crumb] = []
        for folder in folders {
            let label: String = folder.path == "/" ? "Macintosh HD" : folder.lastPathComponent
            result.append(Crumb(id: result.count, label: label,
                                target: .folder(folder), isArchive: false))
        }

        if case .archive(let archive, let inner) = location {
            result.append(Crumb(id: result.count, label: archive.lastPathComponent,
                                target: .archive(archive: archive, inner: ""), isArchive: true))
            var prefix = ""
            let parts: [String] = inner.split(separator: "/").map(String.init)
            for part in parts {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                result.append(Crumb(id: result.count, label: part,
                                    target: .archive(archive: archive, inner: prefix),
                                    isArchive: false))
            }
        }
        return result
    }

    // MARK: - Loading

    func reload() {
        switch location {
        case .folder(let url):
            archiveIndex = nil
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: FileItem.resourceKeys,
                    options: []
                )
                allItems = urls.compactMap(FileItem.init(url:))
                loadError = nil
            } catch {
                allItems = []
                loadError = error.localizedDescription
            }

        case .archive(let archive, let inner):
            do {
                let index = try archiveIndex ?? ArchiveService.index(of: archive)
                archiveIndex = index
                allItems = index.children(of: inner).map { FileItem(node: $0, in: archive) }
                loadError = nil
            } catch {
                allItems = []
                loadError = error.localizedDescription
            }
        }
        let valid = Set(allItems.map(\.url))
        selection.formIntersection(valid)
        marked.formIntersection(valid)
    }

    /// Only real folders are watched; an archive's contents cannot change
    /// under us while we are reading its table of contents.
    private func startWatching() {
        guard case .folder(let url) = location else {
            watcher = nil
            return
        }
        watcher = DirectoryWatcher(url: url) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Navigation

    func go(to target: PaneLocation, recordHistory: Bool = true, select: URL? = nil) {
        guard target != location else { return }
        if case .folder(let url) = target,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            return
        }

        if recordHistory {
            backStack.append(location)
            forwardStack.removeAll()
        }
        // Leaving an archive entirely drops its index; moving about within one keeps it.
        if location.archiveURL != target.archiveURL { archiveIndex = nil }

        location = target
        filter = ""
        selection = select.map { [$0] } ?? []
        marked = []
        reload()
        startWatching()
    }

    func navigate(to url: URL, recordHistory: Bool = true, select: URL? = nil) {
        go(to: .folder(url.standardizedFileURL), recordHistory: recordHistory, select: select)
    }

    /// Step into an archive and show its root.
    func enterArchive(_ archive: URL) {
        go(to: .archive(archive: archive, inner: ""))
    }

    var canGoUp: Bool {
        switch location {
        case .folder(let url): return url.path != "/"
        case .archive: return true          // the archive itself is always above us
        }
    }

    func goUp() {
        switch location {
        case .folder(let url):
            guard url.path != "/" else { return }
            go(to: .folder(url.deletingLastPathComponent()), select: url)

        case .archive(let archive, let inner):
            if inner.isEmpty {
                // Out of the archive, landing on it in its own folder.
                go(to: .folder(archive.deletingLastPathComponent()), select: archive)
            } else {
                var parts = inner.split(separator: "/").map(String.init)
                let leaving = parts.joined(separator: "/")
                parts.removeLast()
                go(to: .archive(archive: archive, inner: parts.joined(separator: "/")),
                   select: URL(fileURLWithPath: archive.path + "/" + leaving))
            }
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        go(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        go(to: next, recordHistory: false)
    }

    /// Enter folders and archives; hand anything else to Launch Services. Files
    /// inside an archive are extracted to a temporary copy first, since there is
    /// nothing on disk to open.
    func open(_ urls: [URL]) {
        let targets = items.filter { urls.contains($0.url) }

        if targets.count == 1, let only = targets.first {
            if only.navigable {
                switch location {
                case .folder:
                    go(to: .folder(only.url))
                case .archive(let archive, _):
                    go(to: .archive(archive: archive, inner: only.archivePath ?? ""))
                }
                return
            }
            // A plain archive sitting in a real folder: step inside it.
            if !only.isVirtual, ArchiveService.isArchive(only.url) {
                enterArchive(only.url)
                return
            }
        }

        for item in targets where !item.navigable {
            if item.isVirtual {
                openVirtualItem(item)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    /// Extracts one entry to a temporary folder and opens that copy. Edits to it
    /// do not travel back into the archive, which is why it is deliberately a
    /// throwaway location.
    private func openVirtualItem(_ item: FileItem) {
        guard case .archive(let archive, let inner) = location,
              let path = item.archivePath else { return }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MACCommander-preview")
            .appendingPathComponent(UUID().uuidString)
        do {
            let depth = inner.isEmpty ? 0 : inner.split(separator: "/").count
            try ArchiveService.extractEntries([path], from: archive, into: temp,
                                              strippingComponents: depth)
            let opened = temp.appendingPathComponent(item.name)
            NSWorkspace.shared.open(opened)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Selects a row by name rather than by URL. `appendingPathComponent` asks
    /// the filesystem what it is building and adds a trailing slash for
    /// directories, so a URL assembled by hand does not compare equal to the one
    /// `contentsOfDirectory` hands back, and the selection silently misses.
    func selectItem(named name: String) {
        guard let match = allItems.first(where: { $0.name == name }) else { return }
        selection = [match.url]
    }

    func selectAll() { selection = Set(items.map(\.url)) }

    func invertSelection() {
        let all = Set(items.map(\.url))
        selection = all.subtracting(selection)
    }
}
