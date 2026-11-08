import AppKit
import Foundation
import UniformTypeIdentifiers

enum SortColumn: String, CaseIterable {
    case name, ext, size, date, attr
}

/// One row in a pane: a directory entry, the ".." row, an entry inside an archive, or a
/// computer's shared folder.
struct FileItem: Identifiable, Hashable {
    /// Where the row points. For ".." it is the folder above; inside an archive it is the
    /// archive's path carried on into it, which names nothing on disk.
    let path: String
    /// The name as it exists, extension included.
    let name: String
    /// Name column: files drop their extension, Total Commander style.
    let displayName: String
    /// Without the dot. Empty for folders, packages shown as folders, and dotfiles.
    let ext: String
    let isDirectory: Bool
    let isParent: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let isReadOnly: Bool
    let isExecutable: Bool
    let size: Int64
    let modified: Date?
    /// True for rows inside an archive. Their path is not on disk.
    let isVirtual: Bool
    /// Path within the archive, for virtual rows only.
    let archivePath: String?
    /// A shared folder in a computer's list of shares.
    let isShare: Bool
    /// A search result: the name column shows the whole path, since the rows come from
    /// all over, and rows are told apart by path.
    let fromResults: Bool

    /// Rows are told apart by name: unique within a listing, and stable across a resync.
    var id: String { isParent ? ".." : fromResults ? path : name }

    var url: URL { URL(fileURLWithPath: path) }

    /// Goes into the pane rather than being opened. Packages (.app) open.
    var navigable: Bool { isDirectory }

    init(path: String, name: String, isDirectory: Bool, isParent: Bool = false,
         isPackage: Bool = false, isSymlink: Bool = false, isHidden: Bool = false,
         isReadOnly: Bool = false, isExecutable: Bool = false, size: Int64 = 0,
         modified: Date? = nil, isVirtual: Bool = false, archivePath: String? = nil,
         isShare: Bool = false, fromResults: Bool = false) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isParent = isParent
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isReadOnly = isReadOnly
        self.isExecutable = isExecutable
        self.size = size
        self.modified = modified
        self.isVirtual = isVirtual
        self.archivePath = archivePath
        self.isShare = isShare
        self.fromResults = fromResults
        let shown = fromResults ? path : name

        // Total Commander splits name and extension into columns, but only for files. A
        // dotfile such as ".gitignore" has no extension and keeps its whole name.
        if !isDirectory && !isParent, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            ext = String(name[name.index(after: dot)...])
            displayName = String(shown.dropLast(ext.count + 1))
        } else {
            displayName = shown
            ext = ""
        }
    }

    static func parent(_ parentPath: String) -> FileItem {
        FileItem(path: parentPath, name: "..", isDirectory: true, isParent: true)
    }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .isWritableKey, .isExecutableKey,
    ]

    /// A row for something on disk. Packages such as .app are shown as files: they open
    /// rather than being gone into.
    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(FileItem.resourceKeys)) else { return nil }
        var isDir = v.isDirectory ?? false
        let isPackage = v.isPackage ?? false
        let isLink = v.isSymbolicLink ?? false
        // A link to a folder is gone into like the folder.
        if isLink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]) {
            isDir = target.isDirectory ?? false
        }
        self.init(path: url.path,
                  name: v.name ?? url.lastPathComponent,
                  isDirectory: isDir && !isPackage,
                  isPackage: isPackage,
                  isSymlink: isLink,
                  isHidden: v.isHidden ?? false,
                  isReadOnly: !(v.isWritable ?? true),
                  isExecutable: !isDir && (v.isExecutable ?? false),
                  size: isDir && !isPackage ? 0 : Int64(v.fileSize ?? 0),
                  modified: v.contentModificationDate)
    }

    /// A row standing for an entry inside an archive.
    init(node: ArchiveNode, in archive: String) {
        self.init(path: archive + "/" + node.path, name: node.name, isDirectory: node.isDirectory,
                  isHidden: node.name.hasPrefix("."), size: node.size, modified: node.modified,
                  isVirtual: true, archivePath: node.path)
    }

    // MARK: - Display

    var sizeText: String {
        if isParent { return "<UP>" }
        if isShare || isDirectory { return "<DIR>" }
        return FileItem.grouped.string(from: NSNumber(value: size)) ?? "\(size)"
    }

    /// Blank when there is no date to show: "..", a shared folder, an unreadable entry.
    var dateText: String {
        guard !isParent, let modified, modified > .distantPast else { return "" }
        return FileItem.dateFormatter.string(from: modified)
    }

    /// r = read-only, h = hidden, l = symbolic link, x = executable.
    var attrText: String {
        if isParent || isShare { return "" }
        return (isReadOnly ? "r" : "-") + (isHidden ? "h" : "-")
             + (isSymlink ? "l" : "-") + (isExecutable ? "x" : "-")
    }

    static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy  HH:mm"
        return f
    }()

    // MARK: - Icons

    private static var iconCache: [String: NSImage] = [:]

    /// Icons cached per kind, except where the icon lives in the file itself (apps,
    /// packages, .icns). Files inside an archive or on another computer always get the
    /// icon for their kind.
    func icon(cheap: Bool) -> NSImage? {
        if isParent { return nil }
        let key: String
        let perFile = !isVirtual && !cheap && (isPackage || ["icns", "app", "webloc"].contains(ext.lowercased()))
        if isDirectory || isShare { key = "<dir>" }
        else if perFile { key = path }
        else { key = "." + ext.lowercased() }
        if let cached = FileItem.iconCache[key] { return cached }

        let image: NSImage
        if isDirectory || isShare {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if perFile {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        FileItem.iconCache[key] = image
        return image
    }
}

/// The line under a pane and the byte formatting it uses.
enum Listing {
    /// What the folder holds, and then what is marked within it, side by side.
    static func summarize(files: Int, dirs: Int, totalBytes: Int64,
                          markedFiles: Int, markedDirs: Int, markedBytes: Int64) -> String {
        let line = "\(plural(files, "file")), \(plural(dirs, "dir"))  —  \(formatBytes(totalBytes))"
        if markedFiles + markedDirs == 0 { return line }
        let what = markedDirs == 0 ? plural(markedFiles, "file")
            : markedFiles == 0 ? plural(markedDirs, "dir")
            : "\(plural(markedFiles, "file")) + \(plural(markedDirs, "dir"))"
        return "\(line)   ·   selected \(what)  —  \(formatBytes(markedBytes))"
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(FileItem.grouped.string(from: NSNumber(value: count)) ?? "\(count)") \(noun)s"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var v = Double(bytes)
        var u = 0
        while v >= 1024 && u < units.count - 1 { v /= 1024; u += 1 }
        if u == 0 { return "\(FileItem.grouped.string(from: NSNumber(value: bytes)) ?? "\(bytes)") B" }
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return "\(f.string(from: NSNumber(value: v)) ?? "\(v)") \(units[u])"
    }

    /// ".." first, then folders, then files. Names use Finder's ordering, so "file9"
    /// comes before "file10".
    static func sort(_ items: inout [FileItem], by column: SortColumn, descending: Bool) {
        items.sort { a, b in
            if a.isParent != b.isParent { return a.isParent }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var r: ComparisonResult
            switch column {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .ext: r = a.ext.localizedStandardCompare(b.ext)
            case .size: r = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .date:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                r = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case .attr: r = a.attrText.compare(b.attrText)
            }
            if r == .orderedSame && column != .name { r = a.name.localizedStandardCompare(b.name) }
            return descending ? r == .orderedDescending : r == .orderedAscending
        }
    }

    /// Wildcard masks, `*.txt;*.log`, as a regular expression.
    static func maskRegex(_ mask: String) -> NSRegularExpression? {
        let parts = mask.split(whereSeparator: { $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let patterns = parts.map { part -> String in
            let escaped = NSRegularExpression.escapedPattern(for: part)
            return "^" + escaped.replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
        }
        return try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: .caseInsensitive)
    }
}
