import AppKit
import SwiftUI

@main
struct MACCommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("MAC Commander", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 760)
        .commands { AppCommands(state: state) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Function keys as menu equivalents. NSF1FunctionKey is 0xF704 and they run on from there.
extension KeyEquivalent {
    static func f(_ n: Int) -> KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(0xF703 + n)!)) }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    /// Whether the keyboard is in a text field: some keys belong to the text there.
    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    var body: some Commands {
        CommandGroup(replacing: .appVisibility) {
            Button("Hide MAC Commander") { NSApp.hide(nil) }
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }

        CommandGroup(replacing: .newItem) {
            Button("View") { state.doView() }.keyboardShortcut(.f(3), modifiers: [])
            Button("Edit") { state.doEdit() }.keyboardShortcut(.f(4), modifiers: [])
            Button("Copy to Other Pane…") { state.doTransfer(move: false) }.keyboardShortcut(.f(5), modifiers: [])
            Button("Move to Other Pane…") { state.doTransfer(move: true) }.keyboardShortcut(.f(6), modifiers: [])
            Button("New Folder…") { state.doNewFolder() }.keyboardShortcut(.f(7), modifiers: [])
            Button("Delete to Trash…") { state.doDelete(toTrash: true) }.keyboardShortcut(.f(8), modifiers: [])
            Button("Delete Permanently…") { state.doDelete(toTrash: false) }.keyboardShortcut(.f(8), modifiers: .shift)
            Divider()
            Button("Rename") { state.active.beginRename() }.keyboardShortcut(.f(2), modifiers: [])
            Button("Rename ") { state.active.beginRename() }.keyboardShortcut(.f(6), modifiers: .shift)
            Button("Multi-Rename Tool…") { state.doMultiRename() }.keyboardShortcut("m", modifiers: .command)
            Divider()
            Button("Pack into Zip File…") { state.doPack() }.keyboardShortcut(.f(5), modifiers: .option)
            Button("Unpack…") { state.doUnpack() }.keyboardShortcut(.f(9), modifiers: .option)
            Button("Look Inside Archive…") { state.peekArchive() }.keyboardShortcut("y", modifiers: .command)
            Button("Find Files…") { state.doSearch() }.keyboardShortcut(.f(7), modifiers: .option)
            Divider()
            Button("Get Info") { state.doProperties() }.keyboardShortcut(.return, modifiers: .option)
            Button("Open Terminal Here") { state.openTerminal() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Show in Finder") { state.openFinder() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            // macOS keeps F5, F6 and the rest for itself unless "Use F1, F2, etc. keys as
            // standard function keys" is on, so every one of them has a ⌘ twin.
            Menu("If Function Keys Are Taken") {
                Button("Rename") { state.active.beginRename() }.keyboardShortcut("2", modifiers: .command)
                Button("View") { state.doView() }.keyboardShortcut("3", modifiers: .command)
                Button("Edit") { state.doEdit() }.keyboardShortcut("4", modifiers: .command)
                Button("Copy to Other Pane…") { state.doTransfer(move: false) }.keyboardShortcut("5", modifiers: .command)
                Button("Move to Other Pane…") { state.doTransfer(move: true) }.keyboardShortcut("6", modifiers: .command)
                Button("New Folder…") { state.doNewFolder() }.keyboardShortcut("7", modifiers: .command)
                Button("Delete to Trash…") { state.doDelete(toTrash: true) }.keyboardShortcut("8", modifiers: .command)
                Button("Delete Permanently…") { state.doDelete(toTrash: false) }.keyboardShortcut("8", modifiers: [.command, .option])
                Divider()
                Button("Pack into Zip File…") { state.doPack() }.keyboardShortcut("5", modifiers: [.command, .option])
                Button("Find Files…") { state.doSearch() }.keyboardShortcut("7", modifiers: [.command, .option])
                Button("Unpack…") { state.doUnpack() }.keyboardShortcut("9", modifiers: [.command, .option])
                Button("Drive List, Left Pane") { state.openDriveList(.left) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Drive List, Right Pane") { state.openDriveList(.right) }.keyboardShortcut("2", modifiers: [.command, .option])
            }
        }

        CommandGroup(replacing: .undoRedo) {
            Button(state.canUndo ? "Undo \(state.undoLabel)" : "Undo") {
                // A text field keeps its own undo.
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
                    text.undoManager?.undo()
                } else {
                    state.undoLast()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Invert Marks") { state.active.invertMarks() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Mark Matching…") { state.markByMask(on: true) }.keyboardShortcut("=", modifiers: [.command, .option])
            Button("Unmark Matching…") { state.markByMask(on: false) }.keyboardShortcut("-", modifiers: [.command, .option])
            Button("Unmark All") { state.active.markAll(false) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Copy Name") { state.copyToClipboard(fullPath: false) }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Copy Full Path") { state.copyToClipboard(fullPath: true) }.keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandMenu("Settings") {
            Button("Multi-Rename Tool…") { state.doMultiRename() }
            Divider()
            Menu("Colours") {
                Toggle("Dark", isOn: Binding(get: { state.settings.theme == .dark }, set: { _ in state.applyTheme(.dark) }))
                Toggle("Light", isOn: Binding(get: { state.settings.theme == .light }, set: { _ in state.applyTheme(.light) }))
            }
            Menu("Interface Size") {
                ForEach(UIScale.ladder, id: \.self) { step in
                    let toggle = Toggle("\(Int(step * 100))%", isOn: Binding(
                        get: { abs(state.settings.uiScale - step) < 0.001 }, set: { _ in state.applyScale(step) }))
                    if step == 1.0 { toggle.keyboardShortcut("0", modifiers: .command) } else { toggle }
                }
                Divider()
                Button("Bigger") { state.stepScale(1) }.keyboardShortcut("+", modifiers: .command)
                Button("Bigger ") { state.stepScale(1) }.keyboardShortcut("=", modifiers: .command)
                Button("Smaller") { state.stepScale(-1) }.keyboardShortcut("-", modifiers: .command)
            }
            Divider()
            Toggle("Show Hidden Files", isOn: Binding(get: { state.left.showHidden }, set: { _ in state.toggleHidden() }))
                .keyboardShortcut("h", modifiers: .command)
            Button("Show Hidden Files ") { state.toggleHidden() }.keyboardShortcut(".", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            Button("Up One Level") { state.active.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Back") { state.active.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { state.active.goForward() }.keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Switch Pane") { state.toggleActiveSide() }.keyboardShortcut("\\", modifiers: .command)
            Button("Swap Panes") { state.swapPanels() }.keyboardShortcut("u", modifiers: .command)
            Button("Match Panes") { state.matchPanes() }.keyboardShortcut("=", modifiers: [.command, .shift])
            Button("Highlighted Folder in Other Pane  (⌘← ⌘→)") { state.targetEqualsSource() }
            Button("Refresh Both Panes") { state.refreshBoth() }.keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Drive List, Left Pane") { state.openDriveList(.left) }.keyboardShortcut(.f(1), modifiers: .option)
            Button("Drive List, Right Pane") { state.openDriveList(.right) }.keyboardShortcut(.f(2), modifiers: .option)
            Button("Home") { state.openFolder(Paths.home) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            ForEach(state.bookmarks.items) { bookmark in
                Button(bookmark.name) { state.openFolder(bookmark.path) }
            }
            Divider()
            Button("Bookmark This Folder") { state.bookmarkActiveDirectory() }.keyboardShortcut("d", modifiers: .command)
            Button("Manage Bookmarks…") {
                Task {
                    _ = await state.present { (done: @escaping (Bool?) -> Void) in
                        BookmarksSheet(store: state.bookmarks, onClose: { done(true) })
                    }
                }
            }
            Button("Add This Folder to the Toolbar") {
                state.dropOnToolbar([state.active.realFolder], row: 0)
            }
            .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { NSApp.keyWindow?.miniaturize(nil) }
            Button("Zoom") { NSApp.keyWindow?.zoom(nil) }
        }
    }
}
