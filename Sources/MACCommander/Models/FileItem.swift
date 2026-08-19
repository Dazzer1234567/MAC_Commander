import AppKit
import Foundation
import UniformTypeIdentifiers

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

    /// True for rows that describe an entry inside an archive rather than a
    /// file on disk. Their `url` is an identifier, not something that can be
    /// opened, so anything touching the filesystem must check this first.
    let isVirtual: Bool

    /// Path within the archive, for virtual rows only.
    let archivePath: String?

    var id: URL { url }

    /// Packages (.app, .rtfd) look like folders on disk but should open, not descend.
    var navigable: Bool { isDirectory && !isPackage }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// A row standing for an entry inside an archive. The URL is synthesised
    /// as archive-path + inner-path: it never exists on disk, but it is stable
    /// and unique, which is all the table needs for identity and selection.
    init(node: ArchiveNode, in archive: URL) {
        self.url = URL(fileURLWithPath: archive.path + "/" + node.path)
        self.name = node.name
        self.isDirectory = node.isDirectory
        self.isPackage = false
        self.isSymlink = false
        self.isHidden = node.name.hasPrefix(".")
        self.size = node.size
        self.modified = node.modified
        self.isVirtual = true
        self.archivePath = node.path
    }

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
        self.isVirtual = false
        self.archivePath = nil
    }
}

extension FileItem {
    /// Extension shown in its own column. Folders have none; packages like .app
    /// do, since they behave as files here.
    var ext: String {
        navigable ? "" : url.pathExtension
    }

    /// The name with the extension taken off, so the Name column spends its
    /// width on the part that actually distinguishes one file from another.
    /// A dotfile such as ".gitignore" has no extension and keeps its full name.
    var baseName: String {
        ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    }

    var displaySize: String {
        navigable ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayDate: String {
        modified == .distantPast ? "—" : FileItem.dateFormatter.string(from: modified)
    }

    var icon: NSImage {
        // Virtual rows have no file to ask about, so the icon comes from the
        // name's type instead of the path.
        let image: NSImage
        if isVirtual {
            let type = isDirectory
                ? UTType.folder
                : (UTType(filenameExtension: url.pathExtension) ?? .data)
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
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
