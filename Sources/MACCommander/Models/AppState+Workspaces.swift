import AppKit
import Foundation

/// What a properties dialog for a shortcut or layout ended with.
enum ShortcutResult { case saved, deleted, cancelled }

/// The workspace toolbar, the saved pane layouts and the centre strip.
extension AppState {
    var currentWorkspace: Workspace {
        settings.workspaces.first { $0.name == settings.activeWorkspace } ?? settings.workspaces[0]
    }

    func selectWorkspace(_ workspace: Workspace) {
        settings.activeWorkspace = workspace.name
        changed()
        active.focusRequest += 1
    }

    // MARK: - Workspaces

    /// Prompts for a name and rejects blanks and duplicates. Nil means cancelled.
    func askWorkspaceName(_ title: String, _ prompt: String, initial: String, allow: Workspace? = nil) async -> String? {
        var initial = initial
        while true {
            guard let typed = await ask(title, prompt, initial: initial)?.trimmingCharacters(in: .whitespaces),
                  !typed.isEmpty else { return nil }
            if let clash = settings.workspaces.first(where: { $0 !== allow && $0.name.caseInsensitiveCompare(typed) == .orderedSame }) {
                warn("A workspace called \"\(clash.name)\" already exists.")
                initial = typed
                continue
            }
            return typed
        }
    }

    @discardableResult
    func addWorkspace() async -> Workspace? {
        guard let name = await askWorkspaceName("New workspace", "Name the new workspace:", initial: "") else { return nil }
        let workspace = Workspace(name: name)
        settings.workspaces.append(workspace)
        changed()
        return workspace
    }

    func renameWorkspace(_ workspace: Workspace) {
        Task {
            guard let name = await askWorkspaceName("Rename workspace", "New name:", initial: workspace.name, allow: workspace)
            else { return }
            let wasActive = settings.activeWorkspace == workspace.name
            workspace.name = name
            if wasActive { settings.activeWorkspace = name }
            changed()
        }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        guard settings.workspaces.count > 1 else {
            warn("This is the only workspace - there has to be at least one.")
            return
        }
        let shortcuts = workspace.buttons.count == 1 ? "1 shortcut" : "\(workspace.buttons.count) shortcuts"
        Task {
            guard await confirm("Delete the workspace \"\(workspace.name)\" and its \(shortcuts)?",
                                title: "Delete workspace", ok: "Delete") else { return }
            settings.workspaces.removeAll { $0 === workspace }
            if !settings.workspaces.contains(where: { $0.name == settings.activeWorkspace }) {
                settings.activeWorkspace = settings.workspaces[0].name
            }
            changed()
        }
    }

    func manageWorkspaces() {
        Task {
            _ = await present { (done: @escaping (Bool?) -> Void) in
                WorkspacesSheet(onClose: { done(true) })
            }
            if !settings.workspaces.contains(where: { $0.name == settings.activeWorkspace }) {
                settings.activeWorkspace = settings.workspaces[0].name
            }
            changed()
        }
    }

    // MARK: - Shortcut rows

    func addShortcutRow() {
        currentWorkspace.shortcutRows = max(1, currentWorkspace.shortcutRows) + 1
        changed()
    }

    /// Takes a row away. Nothing on it is lost: its shortcuts go on the end of the row
    /// above, and the rows below move up one.
    func removeShortcutRow(_ row: Int) {
        let workspace = currentWorkspace
        guard row >= 1 else { return }
        let moving = workspace.buttons.filter { $0.row == row }
        workspace.buttons.removeAll { $0.row == row }
        for shortcut in moving { shortcut.row = row - 1 }
        workspace.buttons.append(contentsOf: moving)
        for shortcut in workspace.buttons where shortcut.row > row { shortcut.row -= 1 }
        workspace.shortcutRows = max(1, workspace.shortcutRows - 1)
        changed()
    }

    // MARK: - Shortcuts

    /// Paths dropped onto a row of the toolbar become shortcuts on that row. One that is
    /// already on another row moves here; one already on this row is a slip, and is said so.
    func dropOnToolbar(_ paths: [String], row: Int) {
        let workspace = currentWorkspace
        var added = 0, moved = 0, duplicates = 0
        for path in paths {
            if let existing = workspace.buttons.first(where: { $0.target.caseInsensitiveCompare(path) == .orderedSame }) {
                if existing.row != row {
                    workspace.buttons.removeAll { $0 === existing }
                    existing.row = row
                    workspace.buttons.append(existing)
                    moved += 1
                } else {
                    duplicates += 1
                }
                continue
            }
            workspace.buttons.append(Shortcut(label: Paths.shortcutLabel(for: path), target: path, row: row,
                                              showLabel: !Shortcut.isApplication(path)))
            added += 1
        }
        if added + moved > 0 { changed() }
        // Silently ignoring a duplicate looks exactly like drag and drop being broken.
        if added + moved == 0 && duplicates > 0 {
            flash(duplicates == 1 ? "Already in \"\(workspace.name)\"" : "All \(duplicates) already in \"\(workspace.name)\"")
        }
    }

    /// Whether pressing this shows something in a pane rather than running it.
    func opensInPane(_ shortcut: Shortcut) -> Bool {
        let target = shortcut.target
        if Paths.isDirectory(target) && !Shortcut.isApplication(target) { return true }
        return ArchiveService.isArchive(URL(fileURLWithPath: target)) && FileManager.default.fileExists(atPath: target)
    }

    /// A folder is shown in the active pane; anything else is opened. Shared by the
    /// toolbar and the centre strip so the two behave the same.
    func runShortcut(_ shortcut: Shortcut) {
        if opensInPane(shortcut) {
            openFolder(shortcut.target)
            return
        }
        let url = URL(fileURLWithPath: shortcut.target)
        guard FileManager.default.fileExists(atPath: shortcut.target) else {
            warn("Cannot run \"\(shortcut.label)\":\n\(shortcut.target) is not there.")
            return
        }
        let arguments = shortcut.arguments?.trimmingCharacters(in: .whitespaces) ?? ""
        if Shortcut.isApplication(shortcut.target) {
            let config = NSWorkspace.OpenConfiguration()
            if !arguments.isEmpty { config.arguments = arguments.split(separator: " ").map(String.init) }
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { DispatchQueue.main.async { self.warn("Cannot run \"\(shortcut.label)\":\n\(error.localizedDescription)") } }
            }
        } else if FileManager.default.isExecutableFile(atPath: shortcut.target) && !Paths.isDirectory(shortcut.target) {
            runCommand("\(shellQuote(shortcut.target)) \(arguments)")
        } else if !NSWorkspace.shared.open(url) {
            warn("Cannot open \"\(shortcut.label)\".")
        }
    }

    /// Files dropped on a program's button are handed to that program.
    func openWith(_ shortcut: Shortcut, paths: [String]) {
        guard !paths.isEmpty else { return }
        let app = URL(fileURLWithPath: shortcut.target)
        if Shortcut.isApplication(shortcut.target) {
            NSWorkspace.shared.open(paths.map { URL(fileURLWithPath: $0) }, withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { self.warn("Cannot open that with \"\(shortcut.label)\":\n\(error.localizedDescription)") } }
            }
        } else {
            runCommand(([shortcut.target] + paths).map(shellQuote).joined(separator: " "))
        }
        let what = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items"
        flash("Opened \(what) in \(Paths.shortcutLabel(for: shortcut.target))")
    }

    static let largestShortcutIcon: Double = 36
    static let largestCenterIcon: Double = 42

    func editShortcut(_ shortcut: Shortcut) {
        Task {
            let result = await present { (done: @escaping (ShortcutResult?) -> Void) in
                ShortcutSheet(shortcut: shortcut, largestIcon: AppState.largestShortcutIcon,
                              pathNote: nil, browse: nil, changed: { [weak self] in self?.changed() },
                              onClose: { done($0) })
            }
            if result == .deleted { removeShortcut(shortcut) } else { changed() }
        }
    }

    func removeShortcut(_ shortcut: Shortcut) {
        currentWorkspace.buttons.removeAll { $0 === shortcut }
        changed()
    }

    /// Rearranging: puts `dragged` before `target`, or at the end of `row` when dropped on
    /// the bar itself. Dropped beside a button on another row, it joins that row.
    func moveShortcut(_ dragged: Shortcut, before target: Shortcut?, row: Int) {
        let workspace = currentWorkspace
        guard dragged !== target else { return }
        workspace.buttons.removeAll { $0 === dragged }
        if let target, let index = workspace.buttons.firstIndex(where: { $0 === target }) {
            dragged.row = target.row
            workspace.buttons.insert(dragged, at: index)
        } else {
            dragged.row = row
            workspace.buttons.append(dragged)
        }
        changed()
    }

    func shortcut(withID id: UUID) -> Shortcut? {
        currentWorkspace.buttons.first { $0.id == id }
    }

    // MARK: - Saved pane layouts

    func applyLayout(_ layout: PaneLayout) {
        showListing(left)
        showListing(right)
        for (pane, path) in [(left, layout.leftPath), (right, layout.rightPath)] {
            // A layout whose folder has gone leaves that pane where it is.
            let quiet = pane.warn
            pane.warn = { _ in }
            pane.navigate(path)
            pane.warn = quiet
        }
        active.focusRequest += 1
    }

    /// Offers the two folder names, so OK alone is often enough.
    private func suggestedLayoutName() -> String {
        "\(Paths.leaf(left.currentPath)) / \(Paths.leaf(right.currentPath))"
    }

    func addLayout() {
        let workspace = currentWorkspace
        let layout = PaneLayout(name: suggestedLayoutName(), leftPath: left.currentPath, rightPath: right.currentPath)
        // On the bar before the dialog opens, so width changes have something to resize.
        workspace.layouts.append(layout)
        changed()
        Task {
            let result = await present { (done: @escaping (ShortcutResult?) -> Void) in
                LayoutSheet(layout: layout, isNew: true, preview: { [weak self] in self?.changed() },
                            onClose: { done($0) })
            }
            if result != .saved { workspace.layouts.removeAll { $0 === layout } }
            changed()
        }
    }

    func editLayout(_ layout: PaneLayout) {
        Task {
            let result = await present { (done: @escaping (ShortcutResult?) -> Void) in
                LayoutSheet(layout: layout, isNew: false, preview: { [weak self] in self?.changed() },
                            onClose: { done($0) })
            }
            if result == .deleted { removeLayout(layout) } else { changed() }
        }
    }

    func updateLayoutToCurrent(_ layout: PaneLayout) {
        layout.leftPath = left.currentPath
        layout.rightPath = right.currentPath
        changed()
    }

    func removeLayout(_ layout: PaneLayout) {
        currentWorkspace.layouts.removeAll { $0 === layout }
        changed()
    }

    // MARK: - Centre strip

    func centerClick(_ item: CenterItem) {
        if editingCenter { return }
        if !item.isBuiltIn, let shortcut = item.shortcut {
            runShortcut(shortcut)
            return
        }
        switch item.command {
        case CenterItem.volume: volumeShortcut()
        case CenterItem.match: matchPanes()
        case CenterItem.quickFolder: quickFolder()
        case CenterItem.scratchpad: toggleScratchpad()
        case CenterItem.copyName: copyToClipboard(fullPath: false)
        case CenterItem.copyPath: copyToClipboard(fullPath: true)
        case CenterItem.search: doSearch()
        default: break
        }
    }

    /// Every button on the strip has properties, built-ins included: that is where its
    /// icon is chosen. The quick folder's also changes where it goes.
    func editCenterItem(_ item: CenterItem) {
        let look = item.look
        let isQuickFolder = item.command == CenterItem.quickFolder
        let isVolume = item.command == CenterItem.volume
        if isQuickFolder { look.target = settings.quickFolder }
        if isVolume { look.target = settings.volumePath }
        let note = item.isBuiltIn && !isQuickFolder && !isVolume ? CenterItem.defaultLabels[item.command] ?? item.command : nil
        Task {
            let result = await present { (done: @escaping (ShortcutResult?) -> Void) in
                ShortcutSheet(shortcut: look, largestIcon: AppState.largestCenterIcon, pathNote: note,
                              browse: isQuickFolder || isVolume ? { [weak self] in self?.pickQuickFolder() } : nil,
                              changed: { [weak self] in
                                  guard let self else { return }
                                  if isQuickFolder { self.settings.quickFolder = look.target }
                                  if isVolume { self.settings.volumePath = look.target }
                                  self.changed()
                              },
                              onClose: { done($0) })
            }
            if isQuickFolder && !look.target.isEmpty { settings.quickFolder = look.target }
            if isVolume && !look.target.isEmpty { settings.volumePath = look.target }
            if result == .deleted { settings.centerBar.removeAll { $0 === item } }
            changed()
        }
    }

    /// Folders and programs dropped on the strip become buttons on it, icon only.
    func dropOnCenter(_ paths: [String]) {
        var added = 0, duplicates = 0
        for path in paths {
            if settings.centerBar.contains(where: { $0.shortcut.map { $0.target.caseInsensitiveCompare(path) == .orderedSame } ?? false && !$0.isBuiltIn }) {
                duplicates += 1
                continue
            }
            settings.centerBar.append(CenterItem(shortcut: Shortcut(label: Paths.shortcutLabel(for: path), target: path,
                                                                    showLabel: false)))
            added += 1
        }
        if added > 0 { changed() }
        if added == 0 && duplicates > 0 {
            flash(duplicates == 1 ? "That is already on the strip" : "All \(duplicates) are already on the strip")
        }
    }

    func moveCenterItem(_ dragged: CenterItem, before target: CenterItem?) {
        guard dragged !== target else { return }
        settings.centerBar.removeAll { $0 === dragged }
        if let target, let index = settings.centerBar.firstIndex(where: { $0 === target }) {
            settings.centerBar.insert(dragged, at: index)
        } else {
            settings.centerBar.append(dragged)
        }
        changed()
    }

    func centerItem(withID id: UUID) -> CenterItem? {
        settings.centerBar.first { $0.id == id }
    }
}
