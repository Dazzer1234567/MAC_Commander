import AppKit
import Combine
import Foundation
import SwiftUI

enum Side: Hashable {
    case left, right

    var other: Side { self == .left ? .right : .left }
}

/// The last thing done, stored as whatever is needed to reverse it.
enum UndoableAction {
    case move([PathPair])
    case copy([URL])
    case rename(from: URL, to: URL)

    var label: String {
        switch self {
        case .move(let pairs): return pairs.count == 1 ? "Move" : "Move of \(pairs.count) Items"
        case .copy(let urls): return urls.count == 1 ? "Copy" : "Copy of \(urls.count) Items"
        case .rename: return "Rename"
        }
    }
}

/// A question the app is waiting on: a line of input, a yes/no, or a warning.
struct PromptRequest: Identifiable {
    enum Kind {
        case input(prompt: String, initial: String, selectAll: Bool)
        case confirm(message: String, ok: String)
        case warn(message: String)
    }

    let id = UUID()
    let title: String
    let kind: Kind
    let answer: (String?) -> Void
}

/// A dialog of any kind, shown as a sheet on the main window.
struct SheetRequest: Identifiable {
    let id = UUID()
    let view: AnyView
}

@MainActor
final class AppState: ObservableObject {
    let settings: AppSettings
    let left: PaneModel
    let right: PaneModel
    let jobs = JobCenter()
    let transfer = TransferController()
    let bookmarks = BookmarkStore()

    @Published var activeSide: Side = .left
    @Published var prompt: PromptRequest?
    @Published var sheet: SheetRequest?
    @Published private(set) var toolbarMessage: String?
    @Published private(set) var undoStack: [UndoableAction] = []
    /// Bumped whenever the settings change, so the bars redraw from them.
    @Published private(set) var revision = 0
    /// Rearranging the toolbar, or the centre strip: buttons only move.
    @Published var editingShortcuts = false
    @Published var editingCenter = false
    @Published var computers: [NetworkComputer] = []
    /// Bumped to drop a pane's drive list open, from ⌥F1 / ⌥F2.
    @Published var driveListRequest: [Side: Int] = [.left: 0, .right: 0]

    func openDriveList(_ side: Side) {
        setActive(side)
        driveListRequest[side, default: 0] += 1
    }

    private var pendingPrompts: [PromptRequest] = []
    private var cancellables: Set<AnyCancellable> = []
    private var saveWork: DispatchWorkItem?
    private var messageWork: DispatchWorkItem?

    init() {
        settings = AppSettings.load()
        left = PaneModel(side: .left)
        right = PaneModel(side: .right)

        for pane in [left, right] {
            pane.showHidden = settings.showHidden
            pane.warn = { [weak self] in self?.warn($0) }
            pane.activate = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.setActive(pane.side)
            }
            pane.pathChanged = { [weak self] in self?.pathsChanged() }
            pane.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        ArchiveCleanup.clearOldTemp()
        startIn(left, settings.leftPath)
        startIn(right, settings.rightPath)
        applyTheme(settings.theme, save: false)
        findComputers(timeout: 5)
    }

    var active: PaneModel { activeSide == .left ? left : right }
    var other: PaneModel { activeSide == .left ? right : left }
    func pane(_ side: Side) -> PaneModel { side == .left ? left : right }

    var ui: UI { UI(palette: Palette.of(settings.theme), scale: settings.uiScale) }

    /// Puts a pane back where it was when the app was last closed, which may be inside an
    /// archive. A pane is never left empty: if the place has gone, it starts at home.
    private func startIn(_ pane: PaneModel, _ path: String) {
        let quiet = pane.warn
        pane.warn = { _ in }
        defer { pane.warn = quiet }
        if NetworkPlaces.shareParts(path) == nil, NetworkPlaces.serverOnly(path) == nil, pane.navigate(path) { return }
        pane.navigate(Paths.home)
    }

    func setActive(_ side: Side) {
        guard activeSide != side else { return }
        activeSide = side
        pathsChanged()
    }

    func toggleActiveSide() {
        activeSide = activeSide.other
        active.focusRequest += 1
    }

    private func pathsChanged() {
        NSApp?.mainWindow?.title = "MAC Commander — \(active.currentPath)"
        scheduleSave()
    }

    // MARK: - Settings

    /// Something in the settings changed: redraw what shows them and write them shortly.
    func changed() {
        revision += 1
        scheduleSave()
    }

    /// Writes the settings a moment after something changes, rather than only on the way
    /// out: the process can end without ever closing its window.
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        if !left.showingResults { settings.leftPath = left.currentPath }
        if !right.showingResults { settings.rightPath = right.currentPath }
        settings.showHidden = left.showHidden
        settings.save()
    }

    func applyTheme(_ theme: AppTheme, save: Bool = true) {
        settings.theme = theme
        NSApp?.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        IconLibrary.setInk(Palette.of(theme).text)
        if save { changed() } else { revision += 1 }
    }

    func applyScale(_ scale: Double) {
        settings.uiScale = UIScale.nearest(scale)
        changed()
    }

    func stepScale(_ direction: Int) { applyScale(UIScale.step(from: settings.uiScale, by: direction)) }

    // MARK: - Messages and questions

    /// A note at the right of the toolbar for a couple of seconds.
    func flash(_ text: String) {
        toolbarMessage = text
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toolbarMessage = nil }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func enqueue(_ request: PromptRequest) {
        if prompt == nil { prompt = request } else { pendingPrompts.append(request) }
    }

    /// Called by the prompt sheet once it has its answer.
    func finishPrompt(_ answer: String?) {
        let finished = prompt
        prompt = nil
        finished?.answer(answer)
        if !pendingPrompts.isEmpty {
            let next = pendingPrompts.removeFirst()
            DispatchQueue.main.async { self.prompt = next }
        }
    }

    func warn(_ message: String) {
        enqueue(PromptRequest(title: "MAC Commander", kind: .warn(message: message), answer: { _ in }))
    }

    /// A line of input. Nil means the user backed out.
    func ask(_ title: String, _ prompt: String, initial: String, selectAll: Bool = true) async -> String? {
        await withCheckedContinuation { continuation in
            enqueue(PromptRequest(title: title, kind: .input(prompt: prompt, initial: initial, selectAll: selectAll),
                                  answer: { continuation.resume(returning: $0) }))
        }
    }

    func confirm(_ message: String, title: String, ok: String) async -> Bool {
        await withCheckedContinuation { continuation in
            enqueue(PromptRequest(title: title, kind: .confirm(message: message, ok: ok),
                                  answer: { continuation.resume(returning: $0 != nil) }))
        }
    }

    /// Shows any dialog as a sheet and waits for what it hands back. The view is given a
    /// function to call with its result, or with nil when it is cancelled.
    func present<T, V: View>(_ make: (@escaping (T?) -> Void) -> V) async -> T? {
        await withCheckedContinuation { continuation in
            var answered = false
            let view = make { [weak self] result in
                guard !answered else { return }
                answered = true
                self?.sheet = nil
                continuation.resume(returning: result)
            }
            sheet = SheetRequest(view: AnyView(view.environment(\.ui, ui).environmentObject(self)))
        }
    }

    // MARK: - Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var undoLabel: String { undoStack.last?.label ?? "" }

    func record(_ outcome: TransferOutcome) {
        if !outcome.movedPairs.isEmpty { push(.move(outcome.movedPairs)) }
        if !outcome.createdCopies.isEmpty { push(.copy(outcome.createdCopies)) }
    }

    func push(_ action: UndoableAction) {
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
            for pair in pairs.reversed() { errors += putBack(pair.to, at: pair.from) }
        case .copy(let created):
            // Trash rather than delete, in case the undo itself was a mistake.
            for url in created where FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        catchUpQuietly()
        if !errors.isEmpty { warn(errors.prefix(10).joined(separator: "\n")) }
    }

    /// Moves a file back, refusing to clobber anything that has appeared there since.
    private func putBack(_ current: URL, at original: URL) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: current.path) else {
            return ["\(current.lastPathComponent): not where it was left, so it was not put back"]
        }
        guard !fm.fileExists(atPath: original.path) else {
            return ["\(original.lastPathComponent): something else is already at the original location"]
        }
        do { try fm.moveItem(at: current, to: original); return [] }
        catch { return ["\(current.lastPathComponent): \(error.localizedDescription)"] }
    }

    // MARK: - Other computers

    /// Asks Tailscale which computers are online without holding anything up.
    func findComputers(timeout: TimeInterval) {
        Task.detached(priority: .utility) {
            let found = NetworkPlaces.tailscaleComputers(timeout: timeout)
            await MainActor.run {
                self.computers = found
                self.left.computers = found
                self.right.computers = found
            }
        }
    }
}

/// Throwaway copies of files opened from inside archives.
enum ArchiveCleanup {
    static func clearOldTemp() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MACCommander-preview")
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
