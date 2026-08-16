import AppKit
import SwiftUI

@main
struct MACCommanderApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("MAC Commander", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 1180, height: 700)
        .commands { AppCommands(state: state) }
    }
}

/// Function keys as menu equivalents. NSF1FunctionKey is 0xF704 and they run
/// consecutively from there.
extension KeyEquivalent {
    static let f2 = KeyEquivalent(Character(UnicodeScalar(0xF705)!))
    static let f5 = KeyEquivalent(Character(UnicodeScalar(0xF708)!))
    static let f6 = KeyEquivalent(Character(UnicodeScalar(0xF709)!))
    static let f7 = KeyEquivalent(Character(UnicodeScalar(0xF70A)!))
    static let f8 = KeyEquivalent(Character(UnicodeScalar(0xF70B)!))
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder…") { state.sheet = .newFolder }
                .keyboardShortcut(.f7, modifiers: [])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { state.active.open(Array(state.active.selection)) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(state.active.selection.isEmpty)
            Button("Reveal in Finder") { state.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open Terminal Here") { state.openTerminalHere() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Rename…") { state.requestRename() }
                .keyboardShortcut(.f2, modifiers: [])
                .disabled(state.active.selection.isEmpty)
            Divider()
            Button("Move to Trash") { state.requestTrash() }
                .keyboardShortcut(.f8, modifiers: [])
                .disabled(state.active.selection.isEmpty)
        }

        CommandMenu("Commands") {
            Button("Copy to Other Pane") { state.copyToOtherPane() }
                .keyboardShortcut(.f5, modifiers: [])
                .disabled(state.active.selection.isEmpty)
            Button("Move to Other Pane") { state.moveToOtherPane() }
                .keyboardShortcut(.f6, modifiers: [])
                .disabled(state.active.selection.isEmpty)
            Divider()
            // macOS keeps F5/F6 for dictation and Do Not Disturb unless the user
            // opts into standard function keys, so every F-key has a ⌘ twin here.
            Menu("If Function Keys Are Taken") {
                Button("Rename…") { state.requestRename() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Copy to Other Pane") { state.copyToOtherPane() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Move to Other Pane") { state.moveToOtherPane() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("New Folder…") { state.sheet = .newFolder }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Move to Trash") { state.requestTrash() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            Divider()
            Button("Copy Name") { state.copySelectedNames() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Copy Full Path") { state.copySelectedFullPaths() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .undoRedo) {
            Button(state.canUndo ? "Undo \(state.undoLabel)" : "Undo") { state.undoLast() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!state.canUndo)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All") { state.active.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Invert Selection") { state.active.invertSelection() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Deselect All") { state.active.selection = [] }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Filter This Folder") {
                state.active.filterVisible = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Go") {
            Button("Enclosing Folder") { state.active.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!state.active.canGoUp)
            Button("Back") { state.active.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.active.canGoBack)
            Button("Forward") { state.active.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.active.canGoForward)
            Divider()
            Button("Switch Pane") { state.toggleActiveSide() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Swap Panes") { state.swapPanes() }
                .keyboardShortcut("u", modifiers: .command)
            Button("Other Pane → This Folder") { state.syncOtherPaneToActive() }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("Equal Pane Widths") { state.fitPanes() }
                .keyboardShortcut("=", modifiers: [.command, .option])
            Divider()
            Button("Home") { state.active.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            ForEach(state.bookmarks.items) { bookmark in
                Button(bookmark.name) { state.active.navigate(to: bookmark.url) }
            }
            Divider()
            Button("Bookmark This Folder") { state.bookmarkActiveDirectory() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Manage Bookmarks…") { state.sheet = .manageBookmarks }
            Divider()
            Button("Link This Folder to the Top Bar") { state.linkActiveDirectory() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Remove All Links") { state.links.removeAll() }
                .disabled(state.links.items.isEmpty)
        }

        CommandGroup(after: .toolbar) {
            Button(state.active.showHidden ? "Hide Hidden Files" : "Show Hidden Files") {
                state.active.showHidden.toggle()
                state.inactive.showHidden = state.active.showHidden
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh") { state.refreshBoth() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
