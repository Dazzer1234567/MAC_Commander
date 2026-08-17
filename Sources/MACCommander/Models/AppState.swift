import AppKit
import Combine
import Foundation
import SwiftUI

enum Side: Hashable {
    case left, right

    var other: Side { self == .left ? .right : .left }
}

enum SheetKind: Identifiable {
    case newFolder
    case rename(FileItem)
    case confirmTrash([FileItem])
    case manageBookmarks
    case peekArchive(FileItem)

    var id: String {
        switch self {
        case .newFolder: return "newFolder"
        case .rename(let item): return "rename:\(item.url.path)"
        case .confirmTrash(let items): return "trash:\(items.count):\(items.first?.url.path ?? "")"
        case .manageBookmarks: return "bookmarks"
        case .peekArchive(let item): return "peek:\(item.url.path)"
        }
    }
}

/// The last thing you did, stored as whatever is needed to reverse it.
enum UndoableAction {
    case move([PathPair])
    case copy([URL])
    case rename(from: URL, to: URL)

    var label: String {
        switch self {
        case .move(let pairs):
            return pairs.count == 1 ? "Move" : "Move of \(pairs.count) Items"
        case .copy(let urls):
            return urls.count == 1 ? "Copy" : "Copy of \(urls.count) Items"
        case .rename:
            return "Rename"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var left: PaneModel
    @Published var right: PaneModel
    @Published var activeSide: Side = .left
    @Published var sheet: SheetKind?
    @Published var errorReport: [String] = []
    @Published private(set) var undoStack: [UndoableAction] = []

    /// Width of the left pane. `nil` means "an even split of whatever is
    /// available", which is exactly what the Fit button wants, so Fit is just a
    /// reset rather than a calculation.
    @Published var leftPaneWidth: CGFloat?

    let bookmarks = BookmarkStore()
    let links = LinkStore()
    let transfer = TransferController()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads")
        let secondStart = FileManager.default.fileExists(atPath: downloads.path) ? downloads : home
        left = PaneModel(directory: home)
        right = PaneModel(directory: secondStart)

        // Menu items read pane and bookmark state, so republish when either changes.
        for publisher in [
            left.objectWillChange, right.objectWillChange,
            bookmarks.objectWillChange, links.objectWillChange,
        ] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    var active: PaneModel { activeSide == .left ? left : right }
    var inactive: PaneModel { activeSide == .left ? right : left }

    func pane(_ side: Side) -> PaneModel { side == .left ? left : right }

    // MARK: - Pane management

    func toggleActiveSide() { activeSide = activeSide.other }

    /// Gives both panes the same width.
    func fitPanes() { leftPaneWidth = nil }

    func swapPanes() {
        let leftDir = left.directory
        let rightDir = right.directory
        left.navigate(to: rightDir)
        right.navigate(to: leftDir)
    }

    func syncOtherPaneToActive() {
        inactive.navigate(to: active.directory)
    }

    func refreshBoth() {
        left.reload()
        right.reload()
    }

    // MARK: - File commands

    /// The rows a command should act on: whatever is marked with the space bar,
    /// falling back to the row under the cursor.
    var operands: [FileItem] { active.operationTargets }

    func copyToOtherPane() { runTransfer(.copy) }
    func moveToOtherPane() { runTransfer(.move) }

    private func runTransfer(_ kind: TransferKind) {
        let sources = operands.map(\.url)
        guard !sources.isEmpty, !transfer.isRunning else { return }
        let destination = inactive.directory
        let source = active
        let target = inactive
        Task {
            let outcome = await transfer.run(kind: kind, sources: sources, destination: destination)
            source.reload()
            target.reload()
            record(outcome)
            if !outcome.errors.isEmpty { errorReport = outcome.errors }
        }
    }

    /// Dropping onto a pane moves the files into the folder that pane is showing.
    @discardableResult
    func handleDrop(_ urls: [URL], into side: Side) -> Bool {
        guard !transfer.isRunning else { return false }
        let destination = pane(side).directory
        let origin = pane(side.other)

        // Finder-style: dragging one row of a multi-row selection drags them all.
        var sources = urls
        if let dragged = urls.first,
           urls.count == 1,
           origin.selection.count > 1,
           origin.selection.contains(dragged) {
            sources = origin.selectedItems.map(\.url)
        }

        // A file already living in the destination has nowhere to go.
        sources = sources.filter {
            $0.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL
        }
        guard !sources.isEmpty else { return false }

        Task {
            let outcome = await transfer.run(kind: .move, sources: sources, destination: destination)
            refreshBoth()
            record(outcome)
            if !outcome.errors.isEmpty { errorReport = outcome.errors }
        }
        return true
    }

    // MARK: - Archives

    var selectedArchives: [FileItem] { operands.filter { ArchiveService.isArchive($0.url) } }

    var canExtract: Bool { !selectedArchives.isEmpty && !transfer.isRunning }

    /// Peeking only makes sense for one archive at a time.
    var archiveToPeek: FileItem? {
        let archives = selectedArchives
        return archives.count == 1 ? archives[0] : nil
    }

    func peekArchive() {
        guard let archive = archiveToPeek else { return }
        sheet = .peekArchive(archive)
    }

    func extractToOtherPane() {
        let archives = selectedArchives.map(\.url)
        guard !archives.isEmpty, !transfer.isRunning else { return }
        let destination = inactive.directory
        Task {
            let outcome = await transfer.extract(archives: archives, intoParent: destination)
            refreshBoth()
            // Extraction only creates things, so undo removes them — exactly what
            // the copy case already does.
            if !outcome.createdCopies.isEmpty { push(.copy(outcome.createdCopies)) }
            if !outcome.errors.isEmpty { errorReport = outcome.errors }
        }
    }

    func requestTrash() {
        let items = operands
        guard !items.isEmpty else { return }
        sheet = .confirmTrash(items)
    }

    func performTrash(_ items: [FileItem]) {
        let errors = transfer.trash(items.map(\.url))
        active.selection = []
        refreshBoth()
        if !errors.isEmpty { errorReport = errors }
    }

    func requestRename() {
        guard let item = operands.first else { return }
        sheet = .rename(item)
    }

    func performRename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, !trimmed.contains("/") else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            push(.rename(from: item.url, to: destination))
            active.reload()
            active.selectItem(named: trimmed)
        } catch {
            errorReport = ["Rename failed: \(error.localizedDescription)"]
        }
    }

    func performNewFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let destination = active.directory.appendingPathComponent(trimmed)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            active.reload()
            active.selectItem(named: trimmed)
        } catch {
            errorReport = ["Could not create folder: \(error.localizedDescription)"]
        }
    }

    func revealInFinder() {
        let urls = operands.map(\.url)
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([active.directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func openTerminalHere() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [active.directory],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func bookmarkActiveDirectory() {
        bookmarks.add(active.directory)
    }

    /// Pins the folder the active pane is currently showing to the top bar.
    func linkActiveDirectory() {
        links.add(active.directory)
    }

    // MARK: - Undo

    var canUndo: Bool { !undoStack.isEmpty }

    var undoLabel: String { undoStack.last?.label ?? "" }

    private func record(_ outcome: TransferOutcome) {
        if !outcome.movedPairs.isEmpty { push(.move(outcome.movedPairs)) }
        if !outcome.createdCopies.isEmpty { push(.copy(outcome.createdCopies)) }
    }

    private func push(_ action: UndoableAction) {
        undoStack.append(action)
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    func undoLast() {
        guard let action = undoStack.popLast() else { return }
        var errors: [String] = []

        switch action {
        case .rename(let from, let to):
            errors += putBack(to, at: from)
        case .move(let pairs):
            for pair in pairs.reversed() {
                errors += putBack(pair.to, at: pair.from)
            }
        case .copy(let created):
            // The copies are the only new thing, so undoing means removing them.
            // Trash rather than delete, in case the undo itself was a mistake.
            for url in created where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        refreshBoth()
        if !errors.isEmpty { errorReport = errors }
    }

    /// Moves a file back where it came from, refusing to clobber anything that
    /// has appeared at the original location in the meantime.
    private func putBack(_ current: URL, at original: URL) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: current.path) else {
            return ["\(current.lastPathComponent): not where it was left, so it was not put back"]
        }
        guard !fm.fileExists(atPath: original.path) else {
            return ["\(original.lastPathComponent): something else is already at the original location"]
        }
        do {
            try fm.moveItem(at: current, to: original)
            return []
        } catch {
            return ["\(current.lastPathComponent): \(error.localizedDescription)"]
        }
    }

    // MARK: - Clipboard

    /// Just the names, one per line: "report.pdf". Falls back to the name of the
    /// folder the pane is showing when nothing is selected.
    func copySelectedNames() {
        let items = operands
        copyToPasteboard(
            items.isEmpty
                ? active.directory.lastPathComponent
                : items.map(\.name).joined(separator: "\n")
        )
    }

    /// Absolute paths from the disk root: "/Users/daz/Downloads/report.pdf".
    func copySelectedFullPaths() {
        let items = operands
        copyToPasteboard(
            items.isEmpty
                ? active.directory.path
                : items.map(\.url.path).joined(separator: "\n")
        )
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
