import AppKit
import SwiftUI

/// One pane: drive selector and free space, editable path, the file list (or the
/// scratchpad), and the selection summary.
struct PaneView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var state: AppState
    @Environment(\.ui) private var ui
    @State private var pathText = ""
    @State private var editingPath = false

    private var isActive: Bool { state.activeSide == pane.side }

    var body: some View {
        VStack(spacing: 0) {
            if !pane.scratchpadVisible {
                driveBar
                pathBox
            }
            ZStack(alignment: .bottomLeading) {
                if pane.scratchpadVisible {
                    ScratchpadView(pane: pane, ui: ui)
                } else {
                    FileListView(pane: pane, state: state, ui: ui)
                }
                if !pane.filter.isEmpty && !pane.scratchpadVisible {
                    Text("showing \(pane.filter)*")
                        .font(ui.mono(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, ui.s(8))
                        .padding(.vertical, ui.s(4))
                        .background(RoundedRectangle(cornerRadius: 3).fill(ui.accent))
                        .padding(ui.s(6))
                        .allowsHitTesting(false)
                }
            }
            Text(pane.statusText)
                .font(ui.font(12))
                .foregroundStyle(ui.dim)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ui.s(5))
                .padding(.vertical, ui.s(3))
                .background(ui.header)
        }
        .background(ui.panel)
        // Thickness stays fixed and only the colour changes, so switching panes never
        // nudges the list by a pixel.
        .overlay(Rectangle().strokeBorder(isActive ? ui.palette.borderActive.swiftUI : ui.border, lineWidth: 3))
        .onAppear { pathText = pane.currentPath }
        .onChange(of: pane.location) { _, _ in if !editingPath { pathText = pane.currentPath } }
    }

    private var driveBar: some View {
        HStack(spacing: ui.s(6)) {
            DriveButton(pane: pane, state: state, ui: ui)
                .frame(width: ui.s(160), height: ui.s(24))
                .padding(ui.s(3))
            Text(pane.freeSpaceText)
                .font(ui.font(12))
                .foregroundStyle(ui.dim)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button {
                pane.activate()
                pane.goUp()
                pane.focusRequest += 1
            } label: {
                Text("U").font(ui.font(15, .semibold)).frame(width: ui.s(34), height: ui.s(28))
            }
            .buttonStyle(DazButtonStyle(padding: EdgeInsets()))
            .help("Up one level (Backspace)")
            .padding(EdgeInsets(top: ui.s(3), leading: 0, bottom: ui.s(3), trailing: ui.s(3)))
        }
        .background(ui.header)
        .padding(.top, 3)
        .padding(.horizontal, 3)
    }

    private var pathBox: some View {
        DazTextField(text: $pathText, font: ui.nsFont(12), textColor: ui.palette.text,
                     background: ui.palette.panel,
                     onSubmit: {
                         editingPath = false
                         if !pane.navigate(pathText) { pathText = pane.currentPath }
                         pane.focusRequest += 1
                     },
                     onCancel: {
                         editingPath = false
                         pathText = pane.currentPath
                         pane.focusRequest += 1
                     },
                     onFocus: {
                         editingPath = true
                         pane.activate()
                     })
            .frame(height: ui.s(22))
            .padding(EdgeInsets(top: 0, leading: ui.s(3) + 3, bottom: ui.s(3), trailing: ui.s(3) + 3))
            .background(ui.panel)
    }
}

/// The drive selector: this Mac's volumes, then the other computers on the Tailscale
/// network. Made afresh each time it opens, since drives and computers come and go.
struct DriveButton: NSViewRepresentable {
    @ObservedObject var pane: PaneModel
    @ObservedObject var state: AppState
    let ui: UI

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .flexiblePush
        button.isBordered = true
        button.menu?.delegate = context.coordinator
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.refusesFirstResponder = true
        // The width is the pane's to set, not the longest volume name's.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let c = context.coordinator
        c.pane = pane
        c.state = state
        button.font = ui.nsFont(12)
        c.rebuild()
        if c.shownRequest != state.driveListRequest[pane.side] {
            let first = c.shownRequest == nil
            c.shownRequest = state.driveListRequest[pane.side]
            if !first { DispatchQueue.main.async { button.performClick(nil) } }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        weak var button: NSPopUpButton?
        var pane: PaneModel?
        var state: AppState?
        var shownRequest: Int?
        private var roots: [String] = []

        struct Entry { let root: String; let title: String }

        func entries() -> [Entry] {
            var list: [Entry] = []
            let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
            for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
                let name = (try? url.resourceValues(forKeys: Set(keys)))?.volumeName ?? url.lastPathComponent
                list.append(Entry(root: url.path, title: url.path == "/" ? "/  [\(name)]" : "\(name)"))
            }
            for computer in state?.computers ?? [] {
                list.append(Entry(root: "smb://" + computer.address, title: "\(computer.name)  [Tailscale]"))
            }
            return list
        }

        func rebuild() {
            guard let button, let pane else { return }
            let list = entries()
            let titles = list.map(\.title)
            if titles != button.itemTitles {
                button.removeAllItems()
                button.addItems(withTitles: titles)
            }
            roots = list.map(\.root)
            // The entry for the volume (or computer) the pane is on.
            let current: Int?
            if case .shares(let server) = pane.location {
                current = roots.firstIndex { $0 == "smb://" + server }
            } else {
                let path = pane.realFolder
                current = roots.enumerated()
                    .filter { $0.element.hasPrefix("/") && (path == $0.element || path.hasPrefix($0.element == "/" ? "/" : $0.element + "/")) }
                    .max { $0.element.count < $1.element.count }?.offset
            }
            if let current, button.indexOfSelectedItem != current { button.selectItem(at: current) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            // Ask Tailscale again, briefly; the list fills in if the answer is slow.
            state?.findComputers(timeout: 1.5)
            rebuild()
        }

        @objc func picked(_ sender: NSPopUpButton) {
            guard let pane, roots.indices.contains(sender.indexOfSelectedItem) else { return }
            pane.activate()
            state?.showListing(pane)
            pane.navigate(roots[sender.indexOfSelectedItem])
            pane.focusRequest += 1
            rebuild()
        }
    }
}

/// The plain-text scratchpad shown in place of a pane's listing. Everything typed or
/// pasted is reduced to what ISO 8859-1 can hold, so formatting never comes along.
struct ScratchpadView: NSViewRepresentable {
    @ObservedObject var pane: PaneModel
    let ui: UI

    func makeCoordinator() -> Coordinator { Coordinator(pane: pane) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let old = scroll.documentView as? NSTextView else { return scroll }
        let text = PlainTextView(frame: old.frame, textContainer: old.textContainer)
        text.autoresizingMask = old.autoresizingMask
        text.isVerticallyResizable = true
        text.minSize = old.minSize
        text.maxSize = old.maxSize
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.delegate = context.coordinator
        text.string = pane.scratchpadText
        text.onFocus = { [weak pane] in pane?.activate() }
        scroll.documentView = text
        scroll.hasHorizontalScroller = false
        context.coordinator.text = text
        DispatchQueue.main.async {
            text.window?.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = context.coordinator.text else { return }
        text.font = ui.nsMono(13)
        text.textColor = ui.palette.text
        text.backgroundColor = ui.palette.panel
        text.insertionPointColor = ui.palette.text
        scroll.backgroundColor = ui.palette.panel
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let pane: PaneModel
        weak var text: NSTextView?
        init(pane: PaneModel) { self.pane = pane }

        func textDidChange(_ notification: Notification) {
            pane.scratchpadText = text?.string ?? ""
        }
    }
}

/// A text view that only ever takes plain text in.
final class PlainTextView: NSTextView {
    var onFocus: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }

    /// Asks the pasteboard for its plain-text flavour specifically: the HTML and RTF
    /// versions carry the formatting we are trying to be rid of.
    override func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        insertText(PlainText.clean(raw), replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    /// Typed characters get the same treatment, so the two routes agree.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if typed.isEmpty || PlainText.isClean(typed) {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let cleaned = PlainText.clean(typed)
        if !cleaned.isEmpty { super.insertText(cleaned, replacementRange: replacementRange) }
    }
}
