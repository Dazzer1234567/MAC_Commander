import AppKit
import Foundation

/// The file commands: function keys, the centre strip, the command line.
extension AppState {
    /// Says why not, and returns true, where the active pane cannot be changed: inside an
    /// archive, or in a computer's list of shares.
    func readOnlyHere(_ what: String) -> Bool {
        if active.inShareList {
            warn("\(what) is not possible in a computer's list of shared folders.\n\n"
                 + "Open one of the shared folders first. Sharing a new one is done on the computer that has it.")
            return true
        }
        if active.inArchive {
            warn("\(what) is not possible inside an archive.\n\n"
                 + "An archive can be looked into and copied out of, with F5. To change what is in it, copy it out first.")
            return true
        }
        if active.showingResults && what != "Deleting" && what != "Renaming" && what != "Editing a file" {
            warn("\(what) is not possible in a list of search results.")
            return true
        }
        return false
    }

    // MARK: - F3 / F4

    func doView() {
        guard let path = active.readableCursorFile() else { return }
        Task { _ = await present { (done: @escaping (Bool?) -> Void) in ViewerSheet(path: path, onClose: { done(true) }) } }
    }

    func doEdit() {
        guard let item = active.cursorItem, !item.isDirectory, !item.isParent else { return }
        // An editor would be given a temporary copy, and what was saved to it would go
        // nowhere - which looks exactly like the edit having worked.
        if readOnlyHere("Editing a file") { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", settings.editor, item.path]
        do { try process.run() } catch { warn("Cannot start editor:\n\(error.localizedDescription)") }
    }

    // MARK: - F5 / F6

    func doTransfer(move: Bool) {
        let items = active.actionItems
        guard !items.isEmpty else { return }
        if move && readOnlyHere("Moving files out") { return }
        let verb = move ? "Move" : "Copy"

        if other.inShareList {
            warn("The other pane shows a computer's shared folders, not a folder.\n\n"
                 + "Open one of them there first, then \(verb.lowercased()) into it.")
            return
        }

        // The other pane may be inside an archive, where nothing can be put. The folder its
        // archive is in is the nearest place that can take a copy, and is only a suggestion.
        let destination = other.realFolder
        let initial = items.count == 1
            ? (destination as NSString).appendingPathComponent(items[0].name)
            : destination + "/"
        let prompt = items.count == 1 ? "\(verb) \"\(items[0].name)\" to:" : "\(verb) \(items.count) selected items to:"
        let source = active

        Task {
            guard let typed = await ask(verb, prompt, initial: initial),
                  !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let target = Paths.resolve(typed, relativeTo: source.realFolder)

            if ArchiveService.locate(target) != nil {
                warn("That is inside an archive, and nothing can be put into one from here.\n\n\(target)")
                return
            }

            // Where it goes: into an existing folder under their own names; one item to a
            // path that is not a folder is a copy-and-rename; several items to a new folder.
            let folder: String
            var rename: String?
            if Paths.isDirectory(target) {
                folder = target
            } else if items.count == 1 {
                folder = (target as NSString).deletingLastPathComponent
                rename = (target as NSString).lastPathComponent
                guard Paths.isDirectory(folder) else {
                    warn("\(verb) failed:\nThere is no folder \(folder)")
                    return
                }
            } else {
                do { try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true) }
                catch { warn("\(verb) failed:\n\(error.localizedDescription)"); return }
                folder = target
            }

            let mark = jobs.mark
            let job = jobs.start(move ? "Moving" : "Copying")
            let outcome: TransferOutcome
            if let (archive, inner) = source.archive {
                let depth = inner.isEmpty ? 0 : inner.split(separator: "/").count
                outcome = await transfer.copyOut(paths: items.compactMap(\.archivePath), from: URL(fileURLWithPath: archive),
                                                 strippingComponents: depth, to: URL(fileURLWithPath: folder),
                                                 rename: rename, job: job)
            } else {
                outcome = await transfer.run(kind: move ? .move : .copy, sources: items.map(\.url),
                                             destination: URL(fileURLWithPath: folder), rename: rename, job: job)
            }
            jobs.finish(job)
            finishTransfer(outcome, verb: verb, folder: folder,
                           names: rename.map { [$0] } ?? items.map(\.name), mark: mark)
        }
    }

    /// Files dragged onto a pane: copied, or moved with ⌘ held, straight into the folder
    /// they were dropped on. No dialog: where they go was shown by where they were dropped.
    func transferDropped(_ paths: [String], into folder: String, move: Bool) {
        let mark = jobs.mark
        let job = jobs.start(move ? "Moving" : "Copying")
        Task {
            let outcome = await transfer.run(kind: move ? .move : .copy, sources: paths.map { URL(fileURLWithPath: $0) },
                                             destination: URL(fileURLWithPath: folder), job: job)
            jobs.finish(job)
            finishTransfer(outcome, verb: move ? "Move" : "Copy", folder: folder,
                           names: paths.map { ($0 as NSString).lastPathComponent }, mark: mark)
        }
    }

    /// Lands the cursor on what was just copied, in whichever pane shows where it went. An
    /// operation that ran long enough to show its box leaves the cursor where it is: the
    /// user may well have moved on meanwhile.
    private func finishTransfer(_ outcome: TransferOutcome, verb: String, folder: String, names: [String], mark: Int) {
        record(outcome)
        if !outcome.errors.isEmpty { warn("\(verb) failed for some items:\n" + listed(outcome.errors)) }

        if jobs.appeared(since: mark) {
            catchUpQuietly()
            return
        }
        refreshBoth(landed: (folder, names.first ?? ""))
        let succeeded = outcome.errors.isEmpty && !outcome.cancelled
        if succeeded, let pane = [other, active].first(where: { Paths.same($0.currentPath, folder) }) {
            if names.count > 1 { pane.markNames(names) }
            setActive(pane.side)
            pane.focusRequest += 1
        }
    }

    // MARK: - F7 / F8

    func doNewFolder() {
        if active.scratchpadVisible { return }
        if readOnlyHere("Making a folder") { return }
        guard let folder = active.writableFolder else { return }
        // Start from the folder under the cursor, fully selected, to keep, edit or wipe.
        let suggested = active.cursorItem.flatMap { $0.isDirectory && !$0.isParent ? $0.name : nil } ?? "New folder"
        let pane = active
        Task {
            guard let typed = await ask("New folder", "Create directory:", initial: suggested),
                  !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let name = typed.trimmingCharacters(in: .whitespaces)
            let path = Paths.resolve(name, relativeTo: folder)
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                pane.refresh(focus: (name as NSString).pathComponents.first ?? name)
            } catch {
                warn("Cannot create directory:\n\(error.localizedDescription)")
            }
        }
    }

    func doDelete(toTrash: Bool) {
        if readOnlyHere("Deleting") { return }
        let items = active.actionItems
        guard !items.isEmpty else { return }
        let what = items.count == 1 ? "\"\(items[0].name)\"" : "\(items.count) selected items"
        let how = toTrash ? "to the Trash" : "permanently (cannot be undone)"
        Task {
            guard await confirm("Delete \(what) \(how)?", title: "Delete", ok: "Delete") else { return }
            let mark = jobs.mark
            let job = jobs.start("Deleting")
            let errors = await transfer.delete(items.map(\.url), toTrash: toTrash, job: job)
            jobs.finish(job)
            if !errors.isEmpty { warn("Delete failed:\n" + listed(errors)) }
            if jobs.appeared(since: mark) { catchUpQuietly() } else { refreshBoth() }
        }
    }

    // MARK: - Other commands

    /// Num +/-: mark or unmark files matching a wildcard, `*.txt;*.log`.
    func markByMask(on: Bool) {
        let pane = active
        guard !pane.scratchpadVisible else { return }
        Task {
            guard let mask = await ask(on ? "Select" : "Unselect",
                                       on ? "Select files matching:" : "Unselect files matching:", initial: "*.*"),
                  !mask.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            pane.mark(byMask: mask, on: on)
        }
    }

    func doMultiRename() {
        let items = active.actionItems
        guard !items.isEmpty else { return }
        if readOnlyHere("Renaming") { return }
        Task {
            let renamed = await present { (done: @escaping (Bool?) -> Void) in
                MultiRenameSheet(urls: items.map(\.url), onClose: { done($0) })
            }
            if renamed == true { refreshBoth() }
        }
    }

    func doSearch() {
        let start = active.realFolder
        Task {
            let outcome = await present { (done: @escaping (SearchOutcome?) -> Void) in
                SearchSheet(startFolder: start, onClose: { done($0) })
            }
            switch outcome {
            case .goTo(let url):
                showListing(active)
                active.navigate(url.deletingLastPathComponent().path, focus: url.lastPathComponent)
            case .feed(let urls):
                showListing(active)
                active.showResults(urls)
            case nil:
                break
            }
        }
    }

    /// ⌥↩: the Finder's Get Info window, for things on disk.
    func doProperties() {
        guard let item = active.cursorItem, !item.isParent, !item.isVirtual, !item.isShare else { return }
        let escaped = item.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { warn("Cannot show its info:\n\(error[NSAppleScript.errorMessage] ?? error)") }
    }

    /// Brings both listings up to date after something finished in the background, keeping
    /// cursors, marks and typed filters: nobody asked for them to change.
    func catchUpQuietly() {
        left.resync()
        right.resync()
    }

    /// A file to put the cursor on, in whichever pane shows the folder it is in.
    func refreshBoth(landed: (folder: String, name: String)? = nil) {
        for pane in [left, right] {
            let focus = landed.flatMap { Paths.same(pane.currentPath, $0.folder) ? $0.name : nil }
            pane.refresh(focus: focus)
        }
    }

    func swapPanels() {
        let leftLocation = left.location
        left.go(to: right.location)
        right.go(to: leftLocation)
        active.focusRequest += 1
    }

    /// Shows the active pane's folder in the other pane. It mirrors the folder you are in,
    /// ignoring what the cursor is on; the active pane stays active.
    func matchPanes() {
        showListing(other)
        other.go(to: active.location)
        active.focusRequest += 1
    }

    /// ⌘← / ⌘→: shows the highlighted folder (or the current one) in the other pane.
    func targetEqualsSource() {
        let path: String
        if let cursor = active.cursorItem, !cursor.isParent,
           cursor.isDirectory || cursor.isShare || (!cursor.isVirtual && ArchiveService.isArchive(cursor.url)) {
            if cursor.isDirectory, let (a, _) = active.archive {
                path = a + "/" + (cursor.archivePath ?? "")
            } else {
                path = cursor.path
            }
        } else {
            path = active.currentPath
        }
        showListing(other)
        other.navigate(path)
        active.focusRequest += 1
    }

    func toggleHidden() {
        let show = !left.showHidden
        left.setShowHidden(show)
        right.setShowHidden(show)
        settings.showHidden = show
        changed()
    }

    // MARK: - Panes and folders

    /// Gives a pane its listing back if it is showing the scratchpad. The text is kept.
    func showListing(_ pane: PaneModel) {
        guard pane.scratchpadVisible else { return }
        pane.showScratchpad(false)
    }

    /// A folder button: shows its folder in the active pane, every time. A link and not a
    /// switch, so pressing it again stays there and never goes back.
    func openFolder(_ folder: String) {
        showListing(active)
        active.navigate(folder)
        active.focusRequest += 1
    }

    func toggleScratchpad() {
        active.showScratchpad(!active.scratchpadVisible)
        objectWillChange.send()
    }

    func volumeShortcut() {
        guard Paths.isDirectory(settings.volumePath) else {
            warn("\(settings.volumePath) is not available.")
            return
        }
        openFolder(settings.volumePath)
    }

    func quickFolder() {
        guard Paths.isDirectory(settings.quickFolder) else {
            warn("That folder is no longer there:\n\(settings.quickFolder)\n\n⌘-click the button to pick another.")
            return
        }
        openFolder(settings.quickFolder)
    }

    /// Asks for the folder the arrow jumps to. Nil means the user backed out.
    func pickQuickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder this button jumps to"
        let start = Paths.isDirectory(settings.quickFolder) ? settings.quickFolder : active.realFolder
        panel.directoryURL = URL(fileURLWithPath: start)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: - Clipboard

    /// The marked entries, or the one under the cursor, one per line. Names include the
    /// extension, which is what gets pasted back into a command line or a document.
    func copyToClipboard(fullPath: Bool) {
        let items = active.actionItems
        guard !items.isEmpty else { return }
        let text = items.map { fullPath ? $0.path : $0.name }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            warn("The clipboard could not be written - try again in a moment.")
            return
        }
        if items.count == 1 {
            let name = items[0].name
            flash(fullPath ? "Copied full path of \(name)" : "Copied name: \(name)")
        } else {
            flash("Copied \(items.count) \(fullPath ? "full paths" : "names")")
        }
    }

    // MARK: - Terminal, Finder

    func openTerminal() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: active.realFolder)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func openFinder() {
        if let cursor = active.cursorItem, !cursor.isParent, !cursor.isVirtual, !cursor.isShare {
            NSWorkspace.shared.activateFileViewerSelecting([cursor.url])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: active.realFolder))
        }
    }

    // MARK: - Command line

    /// `cd <path>` moves the active pane; anything else runs in a shell in its folder.
    func runCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if trimmed == "cd" || trimmed.lowercased().hasPrefix("cd ") {
            let target = trimmed.count > 2 ? String(trimmed.dropFirst(3)) : "~"
            let base = active.inArchive || active.inShareList ? active.realFolder : active.currentPath
            showListing(active)
            active.navigate(Paths.resolve(target, relativeTo: base))
            active.focusRequest += 1
            return
        }

        // A program has to be started somewhere real; inside an archive that is the folder
        // the archive is in. It runs in Terminal so its output can be read.
        let folder = active.realFolder
        let script = "cd \(shellQuote(folder)) && \(trimmed)"
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """)?.executeAndReturnError(&error)
        if let error { warn("Cannot run command:\n\(error[NSAppleScript.errorMessage] ?? error)") }
    }

    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The first few of a list of things that went wrong, and how many more there were.
    func listed(_ lines: [String]) -> String {
        let shown = lines.prefix(6).joined(separator: "\n")
        return lines.count > 6 ? "\(shown)\n... and \(lines.count - 6) more" : shown
    }

    // MARK: - Archives (kept from the earlier version)

    /// ⌘Y: the top level of one archive, without going into it.
    func peekArchive() {
        guard let item = active.cursorItem, !item.isVirtual, ArchiveService.isArchive(item.url) else { return }
        Task { _ = await present { (done: @escaping (Bool?) -> Void) in PeekSheet(item: item, onClose: { done(true) }) } }
    }

    func bookmarkActiveDirectory() {
        bookmarks.add(URL(fileURLWithPath: active.realFolder))
        flash("Bookmarked \(Paths.leaf(active.realFolder))")
    }
}
