import Foundation

struct ArchiveEntry: Identifiable {
    let name: String
    let isDirectory: Bool
    /// Immediate children, for folders. Nothing deeper is counted.
    let childCount: Int

    var id: String { name }
}

struct ArchiveListing {
    let topLevel: [ArchiveEntry]
    /// Every path in the archive, however deep — for the "N in total" line.
    let totalEntries: Int
}

enum ArchiveError: LocalizedError {
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let message):
            return message.isEmpty ? "The archive could not be read." : message
        }
    }
}

/// Archive support leans entirely on `bsdtar`, which ships with macOS. Its
/// libarchive reads far more than zip — tar and its compressed variants, 7z,
/// iso, and rar read-only — so no third-party dependency is needed.
enum ArchiveService {
    private static let tool = "/usr/bin/bsdtar"

    /// Judged by extension. Sniffing magic bytes would be more accurate but
    /// means opening every file in the pane just to draw a list.
    static let extensions: Set<String> = [
        "zip", "jar", "war", "ipa", "cbz",
        "tar", "tgz", "tbz", "tbz2", "txz", "tzst",
        "gz", "bz2", "xz", "zst", "lz4",
        "7z", "rar", "cbr", "iso", "cpio", "ar", "lha", "lzh",
    ]

    static func isArchive(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Name to give the folder an archive is extracted into: "site.tar.gz"
    /// becomes "site", not "site.tar".
    static func baseName(of url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name.removeLast(4) }
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// Reads the table of contents without extracting anything, then collapses
    /// it to the top level: one row per first path component.
    static func listTopLevel(of archive: URL) throws -> ArchiveListing {
        let output = try run(["-tf", archive.path])

        var files: Set<String> = []
        var folderChildren: [String: Set<String>] = [:]
        var total = 0

        for rawLine in output.split(separator: "\n") {
            var line = String(rawLine)
            if line.hasPrefix("./") { line.removeFirst(2) }
            guard !line.isEmpty, line != "." else { continue }
            total += 1

            let isDirectoryEntry = line.hasSuffix("/")
            let parts = line.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let first = parts.first else { continue }

            if parts.count == 1 {
                if isDirectoryEntry {
                    folderChildren[first] = folderChildren[first] ?? []
                } else {
                    files.insert(first)
                }
            } else {
                folderChildren[first, default: []].insert(parts[1])
            }
        }

        // A name that appears as both is a folder; the bare entry was its own record.
        files.subtract(folderChildren.keys)

        let folders = folderChildren
            .map { ArchiveEntry(name: $0.key, isDirectory: true, childCount: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let plainFiles = files
            .map { ArchiveEntry(name: $0, isDirectory: false, childCount: 0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return ArchiveListing(topLevel: folders + plainFiles, totalEntries: total)
    }

    static func extract(_ archive: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try run(["-x", "-f", archive.path, "-C", folder.path])
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr, as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? ""
            throw ArchiveError.toolFailed(
                message.replacingOccurrences(of: "bsdtar: ", with: ""))
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}
