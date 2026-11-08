import SwiftUI

// STUB - replaced by the find-files port.

enum SearchOutcome {
    case goTo(URL)
    case feed([URL])
}

struct SearchSheet: View {
    let startFolder: String
    let onClose: (SearchOutcome?) -> Void
    var body: some View { StubSheet(title: "Find files in \(startFolder)") { onClose(nil) } }
}
