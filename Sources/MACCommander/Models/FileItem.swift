import AppKit
import Foundation

/// One row in a pane: a single directory entry with the metadata we display.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date

    var id: URL { url }

    /// Packages (.app, .rtfd) look like folders on disk but should open, not descend.
    var navigable: Bool { isDirectory && !isPackage }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
    ]

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(FileItem.resourceKeys)) else { return nil }
        self.url = url
        self.name = v.name ?? url.lastPathComponent
        self.isDirectory = v.isDirectory ?? false
        self.isPackage = v.isPackage ?? false
        self.isSymlink = v.isSymbolicLink ?? false
        self.isHidden = v.isHidden ?? false
        self.size = Int64(v.fileSize ?? 0)
        self.modified = v.contentModificationDate ?? .distantPast
    }
}

extension FileItem {
    var displaySize: String {
        navigable ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayDate: String {
        modified == .distantPast ? "—" : FileItem.dateFormatter.string(from: modified)
    }

    var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
