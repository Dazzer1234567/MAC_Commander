import Foundation

/// One entry inside an archive, as read from the table of contents.
struct ArchiveNode {
    let path: String          // full path inside the archive, no trailing slash
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
}

/// The whole table of contents, bucketed by parent directory so any folder in
/// the archive can be listed instantly once the index is built.
///
/// Built from `bsdtar -tvf`, which reads the archive's directory without
/// extracting a byte. That is what makes browsing feel immediate even on a
/// large archive — the cost is one listing, not an unpack.
struct ArchiveIndex {
    let archive: URL
    private let childrenByParent: [String: [ArchiveNode]]

    /// "" is the archive root; otherwise a path like "proj/src".
    func children(of parent: String) -> [ArchiveNode] {
        childrenByParent[parent] ?? []
    }

    func containsDirectory(_ path: String) -> Bool {
        path.isEmpty || childrenByParent[path] != nil
    }

    var totalEntries: Int {
        childrenByParent.values.reduce(0) { $0 + $1.count }
    }

    init(archive: URL, verboseListing: String) {
        self.archive = archive

        var nodes: [String: ArchiveNode] = [:]        // path -> node
        var directories: Set<String> = []

        for line in verboseListing.split(separator: "\n") {
            guard let parsed = ArchiveIndex.parse(String(line)) else { continue }
            if parsed.isDirectory {
                directories.insert(parsed.path)
            }
            nodes[parsed.path] = parsed

            // Some archives omit entries for intermediate folders, so synthesise
            // every ancestor of every path rather than trusting the listing.
            var components = parsed.path.split(separator: "/").map(String.init)
            components.removeLast()
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                directories.insert(prefix)
                if nodes[prefix] == nil {
                    nodes[prefix] = ArchiveNode(
                        path: prefix, name: component, isDirectory: true,
                        size: 0, modified: parsed.modified)
                }
            }
        }

        // Anything recorded as a directory wins over a same-named file entry.
        for path in directories {
            if let existing = nodes[path], !existing.isDirectory {
                nodes[path] = ArchiveNode(
                    path: path, name: existing.name, isDirectory: true,
                    size: 0, modified: existing.modified)
            }
        }

        var buckets: [String: [ArchiveNode]] = [:]
        for node in nodes.values {
            let parent = node.path.contains("/")
                ? String(node.path[..<node.path.lastIndex(of: "/")!])
                : ""
            buckets[parent, default: []].append(node)
        }
        // Make sure every directory has a bucket, even when empty.
        for path in directories where buckets[path] == nil {
            buckets[path] = []
        }
        self.childrenByParent = buckets
    }

    /// `drwxr-xr-x  0 daz  wheel  0 Aug 19 13:37 proj/src/main.swift`
    ///
    /// The layout is fixed by libarchive across zip, tar and 7z: mode, links,
    /// owner, group, size, then a three-field date, then the path — which may
    /// itself contain spaces, so only the first eight fields are split off.
    static func parse(_ line: String) -> ArchiveNode? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9 else { return nil }

        let mode = fields[0]
        let isDirectory = mode.hasPrefix("d")
        let size = Int64(fields[4]) ?? 0
        let modified = parseDate(month: String(fields[5]),
                                 day: String(fields[6]),
                                 yearOrTime: String(fields[7]))

        var path = String(fields[8])
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path != "." else { return nil }

        let name = path.contains("/")
            ? String(path[path.index(after: path.lastIndex(of: "/")!)...])
            : path
        return ArchiveNode(path: path, name: name, isDirectory: isDirectory,
                           size: size, modified: modified)
    }

    /// listings show "Aug 19 13:37" for recent entries and "Aug 19 2024" for old ones.
    private static func parseDate(month: String, day: String, yearOrTime: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if yearOrTime.contains(":") {
            formatter.dateFormat = "MMM d HH:mm yyyy"
            let year = Calendar.current.component(.year, from: Date())
            return formatter.date(from: "\(month) \(day) \(yearOrTime) \(year)") ?? .distantPast
        }
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: "\(month) \(day) \(yearOrTime)") ?? .distantPast
    }
}
