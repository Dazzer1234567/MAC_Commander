import SwiftUI

/// The vertical strip between the two panes.
///
/// It holds the actions that are inherently *about* both panes, where a
/// left/right arrow says which way things travel. Clicks here deliberately do
/// not change which pane is active — `PaneClickWatcher` only reacts to clicks
/// inside a pane's own bounds — so pressing Copy sends from the pane you were
/// working in, not from whichever one you touched last.
struct CenterBar: View {
    @ObservedObject var state: AppState

    /// Single place to tune the width.
    static let width: CGFloat = 50

    private var pointsRight: Bool { state.activeSide == .left }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 12)

            button(
                systemImage: pointsRight ? "arrow.right.doc.on.clipboard" : "arrow.right.doc.on.clipboard",
                title: "Copy",
                help: "Copy to the \(pointsRight ? "right" : "left") pane — F5",
                enabled: !state.operands.isEmpty,
                flipped: !pointsRight
            ) { state.copyToOtherPane() }

            button(
                systemImage: "arrow.right.square",
                title: "Move",
                help: "Move to the \(pointsRight ? "right" : "left") pane — F6",
                enabled: !state.operands.isEmpty,
                flipped: !pointsRight
            ) { state.moveToOtherPane() }

            button(
                systemImage: "arrow.up.bin",
                title: "Unzip",
                help: "Extract to the \(pointsRight ? "right" : "left") pane — ⌘E",
                enabled: state.canExtract,
                flipped: !pointsRight
            ) { state.extractToOtherPane() }

            Divider().padding(.horizontal, 8)

            button(
                systemImage: "arrow.left.arrow.right",
                title: "Swap",
                help: "Swap the two panes — ⌘U",
                enabled: true,
                flipped: false
            ) { state.swapPanes() }

            button(
                systemImage: "equal.square",
                title: "Same",
                help: "Point the other pane at this folder — ⇧⌘=",
                enabled: true,
                flipped: false
            ) { state.syncOtherPaneToActive() }

            button(
                systemImage: "rectangle.split.2x1",
                title: "Fit",
                help: "Give both panes the same width — ⌥⌘=",
                enabled: true,
                flipped: false
            ) { state.fitPanes() }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
        .overlay(alignment: .trailing) { Divider() }
    }

    private func button(
        systemImage: String,
        title: String,
        help: String,
        enabled: Bool,
        flipped: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .scaleEffect(x: flipped ? -1 : 1, y: 1)
                Text(title)
                    .font(.system(size: 8))
            }
            .frame(width: 38, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
        .help(help)
    }
}
