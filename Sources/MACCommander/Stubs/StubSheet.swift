import SwiftUI

/// Placeholder dialog used by the stubs.
struct StubSheet: View {
    let title: String
    let close: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            Text("Not built yet.")
            Button("Close", action: close).keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
