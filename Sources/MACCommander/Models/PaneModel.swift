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

@MainActor
final class PaneModel: ObservableObject {
    @Published private(set) var directory: URL
    @Published private(set) var allItems: [FileItem] = []
    @Published var selection: Set<URL> = []
    @Published var filter: String = ""
    @Published var filterVisible = false
    @Published var showHidden = false
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [.init(\.name, order: .forward)]
    @Published private(set) var loadError: String?

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?

    init(directory: URL) {
        self.directory = directory
        reload()
        startWatching()
    }

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

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + ($1.navigable ? 0 : $1.size) } }

    var canGoUp: Bool { directory.path != "/" }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The directory chain from `/` down to the current folder, for the breadcrumb bar.
    var ancestry: [URL] {
        var chain: [URL] = []
        var url = directory
        while true {
            chain.append(url)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return chain.reversed()
    }

    // MARK: - Loading

    func reload() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: []
            )
            allItems = urls.compactMap(FileItem.init(url:))
            loadError = nil
        } catch {
            allItems = []
            loadError = error.localizedDescription
        }
        selection.formIntersection(Set(allItems.map(\.url)))
    }

    private func startWatching() {
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL, recordHistory: Bool = true, select: URL? = nil) {
        let target = url.standardizedFileURL
        guard target != directory else { return }
        guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }

        if recordHistory {
            backStack.append(directory)
            forwardStack.removeAll()
        }
        directory = target
        filter = ""
        selection = select.map { [$0] } ?? []
        reload()
        startWatching()
    }

    func goUp() {
        guard canGoUp else { return }
        let leaving = directory
        navigate(to: directory.deletingLastPathComponent(), select: leaving)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(directory)
        navigate(to: previous, recordHistory: false)
    }


    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(directory)
        navigate(to: next, recordHistory: false)
    }

    /// Enter folders; hand files and app bundles to Launch Services.
    func open(_ urls: [URL]) {
        let targets = items.filter { urls.contains($0.url) }
        if targets.count == 1, let only = targets.first, only.navigable {
            navigate(to: only.url)
            return
        }
        for item in targets where !item.navigable {
            NSWorkspace.shared.open(item.url)
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
