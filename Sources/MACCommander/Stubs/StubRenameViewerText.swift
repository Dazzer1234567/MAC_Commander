import SwiftUI

// STUB - replaced by the multi-rename / viewer / plain-text port.

struct MultiRenameSheet: View {
    let urls: [URL]
    let onClose: (Bool) -> Void
    var body: some View { StubSheet(title: "Multi-rename tool") { onClose(false) } }
}

struct ViewerSheet: View {
    let path: String
    let onClose: () -> Void
    var body: some View { StubSheet(title: "Viewer: \(path)") { onClose() } }
}

enum PlainText {
    static func clean(_ text: String) -> String { text }
    static func isClean(_ text: String) -> Bool { true }
}
