import Darwin
import Foundation

// Find Files, after Total Commander's (and DAZ Commander's FileSearch.cs). Nothing here
// knows about the interface, and only Foundation is used, so the matching rules can be
// compiled and tested on their own.

/// How the size of a file is compared against the figure given.
enum SizeComparison: Int {
    case any, atLeast, atMost, exactly
}

/// What to look for.
struct SearchCriteria {
    /// File masks. Several may be given, separated by spaces, commas or semicolons, and
    /// anything after a "|" is excluded instead: `*.swift;*.md | *.generated.swift`.
    var masks = ""

    /// Folders to look in, separated by semicolons.
    var `where` = ""

    var recursive = true

    /// Text the file must contain. Empty searches on name alone.
    var text = ""

    var caseSensitive = false
    var wholeWords = false
    var useRegex = false

    /// Inverts the text test: find the files that do *not* contain it.
    var notContaining = false

    var sizeRule = SizeComparison.any

    /// The figure `sizeRule` compares against, in bytes.
    var sizeBytes: Int64 = 0

    /// Only files changed on or after this.
    var modifiedAfter: Date?

    /// Only files changed on or before this.
    var modifiedBefore: Date?

    /// Dot-files and files with the hidden flag. Hidden folders are skipped with them.
    var includeHidden = false

    /// The folders to start from, one per entry, blanks dropped.
    var roots: [String] {
        `where`.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One file found.
struct SearchHit: Hashable {
    let path: String
    let size: Int64
    let modified: Date?

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Lets the interface stop a search running on another thread. Checked between every
/// entry and every chunk of a file being read, so stopping is prompt.
final class SearchCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}

/// Turns a Total Commander mask line into a test for one file name.
struct FileMask {
    private var include: [NSRegularExpression] = []
    private var exclude: [NSRegularExpression] = []

    /// True when the line named nothing, in which case every name matches.
    var matchesEverything: Bool { include.isEmpty }

    init(_ masks: String, caseSensitive: Bool = false) {
        // Everything after the first "|" is what to leave out.
        let wanted: Substring
        let unwanted: Substring
        if let bar = masks.firstIndex(of: "|") {
            wanted = masks[..<bar]
            unwanted = masks[masks.index(after: bar)...]
        } else {
            wanted = masks[...]
            unwanted = ""
        }

        include = FileMask.split(wanted).compactMap { FileMask.compile($0, caseSensitive) }
        exclude = FileMask.split(unwanted).compactMap { FileMask.compile($0, caseSensitive) }

        // "*" and "*.*" are how everything is usually written, and mean the same as nothing.
        let whole = wanted.trimmingCharacters(in: .whitespaces)
        if include.count == 1 && (whole == "*" || whole == "*.*") { include.removeAll() }
    }

    func matches(_ fileName: String) -> Bool {
        // Names on disk can be in decomposed form (é as e + accent); typed masks are not.
        let name = fileName.precomposedStringWithCanonicalMapping
        let range = NSRange(name.startIndex..., in: name)
        if exclude.contains(where: { $0.firstMatch(in: name, range: range) != nil }) { return false }
        return matchesEverything || include.contains(where: { $0.firstMatch(in: name, range: range) != nil })
    }

    private static func split(_ line: Substring) -> [String] {
        line.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func compile(_ mask: String, _ caseSensitive: Bool) -> NSRegularExpression? {
        var pattern = mask.precomposedStringWithCanonicalMapping

        // A mask with no wildcard in it is a piece of the name to look for, not the whole
        // name - typing "report" finds "Q3 report final.doc", as it does in Total Commander.
        if !pattern.contains("*") && !pattern.contains("?") { pattern = "*" + pattern + "*" }

        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regex += "$"

        return try? NSRegularExpression(pattern: regex, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

/// Finds the text inside one file, whatever encoding it turns out to be in.
struct TextMatcher {
    private let notContaining: Bool
    private let pattern: NSRegularExpression?

    /// Files are read this much at a time, so a huge file neither fills memory nor holds
    /// up a Stop.
    private static let chunk = 1 << 20

    init(_ criteria: SearchCriteria) {
        notContaining = criteria.notContaining

        guard !criteria.text.isEmpty else { pattern = nil; return }

        var source = criteria.useRegex ? criteria.text : NSRegularExpression.escapedPattern(for: criteria.text)

        // Word boundaries only mean anything either side of a word character; wrapping a
        // pattern that starts with punctuation in \b would match nothing at all.
        if criteria.wholeWords && !criteria.useRegex {
            func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
            if let first = criteria.text.first, isWord(first) { source = "\\b" + source }
            if let last = criteria.text.last, isWord(last) { source += "\\b" }
        }

        // Lines are searched a chunk at a time, so ^ and $ have to mean the ends of a line,
        // as they do when the file is read line by line.
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !criteria.caseSensitive { options.insert(.caseInsensitive) }

        // A regex the user is still halfway through typing compiles to nothing, and then
        // the text test is left out rather than failing every file.
        pattern = try? NSRegularExpression(pattern: source, options: options)
    }

    var wanted: Bool { pattern != nil }

    /// Whether the file passes the text test, the "not containing" switch included. Anything
    /// that cannot be read counts as not matching rather than stopping the search.
    func accepts(_ path: String, cancel: SearchCancel? = nil) -> Bool {
        guard let pattern else { return true }
        guard let found = contains(path, pattern, cancel) else { return false }
        return notContaining ? !found : found
    }

    /// Nil when the file could not be read (or the search was stopped part way).
    private func contains(_ path: String, _ pattern: NSRegularExpression, _ cancel: SearchCancel?) -> Bool? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        func hit(_ text: String) -> Bool {
            pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        do {
            var buffer = try handle.read(upToCount: TextMatcher.chunk) ?? Data()

            // A byte-order mark says UTF-16. Such files are rare and small, so they are read
            // whole rather than cut into chunks that could split a character.
            if buffer.starts(with: [0xFF, 0xFE]) || buffer.starts(with: [0xFE, 0xFF]) {
                buffer += try handle.readToEnd() ?? Data()
                let encoding: String.Encoding = buffer[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
                guard let text = String(data: buffer.dropFirst(2), encoding: encoding) else { return nil }
                return hit(text)
            }

            // Everything else is read as UTF-8, which also covers plain ASCII; bytes that are
            // not valid UTF-8 just become replacement characters.
            if buffer.starts(with: [0xEF, 0xBB, 0xBF]) { buffer.removeFirst(3) }

            while true {
                if cancel?.isCancelled == true { return nil }

                let next = try handle.read(upToCount: TextMatcher.chunk) ?? Data()
                let atEnd = next.isEmpty

                // Search up to the last line break and carry the rest into the next round,
                // so no line is cut in two. A stretch with no line break at all (a binary
                // file) is searched as it is, keeping a little overlap.
                var carry = Data()
                if !atEnd {
                    if let lastBreak = buffer.lastIndex(of: 0x0A) {
                        carry = buffer[buffer.index(after: lastBreak)...]
                        buffer = buffer[..<buffer.index(after: lastBreak)]
                    } else if buffer.count > 4096 {
                        carry = buffer.suffix(4096)
                    }
                }

                if hit(String(decoding: buffer, as: UTF8.self)) { return true }
                if atEnd { return false }
                buffer = carry + next
            }
        } catch {
            return nil
        }
    }
}

/// Walks folders and reports what matches.
enum FileSearch {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey,
    ]
    private static let keySet = Set(keys)

    /// Runs the search on the calling thread, calling `found` for each hit as it turns up,
    /// so a long search fills its list as it goes rather than all at the end. `scanning` is
    /// told each folder as it is entered.
    static func run(_ criteria: SearchCriteria, cancel: SearchCancel,
                    scanning: ((String) -> Void)? = nil, found: (SearchHit) -> Void) {
        let mask = FileMask(criteria.masks)
        let text = TextMatcher(criteria)

        // Folders already walked, by device and inode. Symbolic links to folders are never
        // followed, but a folder can still be reached twice (the firmlinks between / and
        // /System/Volumes/Data, a volume mounted inside itself), and this keeps a search
        // from going round in circles or listing everything twice.
        var visited = Set<FolderID>()

        for root in criteria.roots {
            if cancel.isCancelled { return }

            // Folders are taken from a stack rather than by recursion: a deep tree would
            // otherwise run out of a background thread's small stack.
            var stack = [(root as NSString).expandingTildeInPath]

            while let folder = stack.popLast() {
                if cancel.isCancelled { return }

                var info = stat()
                guard stat(folder, &info) == 0 else { continue }
                guard visited.insert(FolderID(device: Int64(info.st_dev), inode: UInt64(info.st_ino))).inserted else { continue }

                scanning?(folder)

                // A folder we may not read is skipped, not fatal. Listing by URL fails on a
                // symbolic link, which only a start folder can be (/tmp, say), so the link is
                // resolved for listing while the results keep the path as it was typed.
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath(),
                    includingPropertiesForKeys: keys, options: []) else { continue }

                var subfolders: [String] = []

                for entry in entries {
                    if cancel.isCancelled { return }
                    guard let values = try? entry.resourceValues(forKeys: keySet) else { continue }
                    let path = (folder as NSString).appendingPathComponent(entry.lastPathComponent)

                    if values.isHidden == true && !criteria.includeHidden { continue }

                    let isLink = values.isSymbolicLink == true

                    if values.isDirectory == true && !isLink {
                        if criteria.recursive { subfolders.append(path) }
                        continue
                    }

                    let name = entry.lastPathComponent
                    if !mask.matches(name) { continue }

                    // A link counts as the file it points to. Links to folders are left
                    // alone, as is anything that is not a plain file (a pipe or a device
                    // would hang the text search).
                    var size = Int64(values.fileSize ?? 0)
                    var modified = values.contentModificationDate
                    if isLink {
                        guard let target = try? entry.resolvingSymlinksInPath().resourceValues(forKeys: keySet),
                              target.isRegularFile == true else { continue }
                        size = Int64(target.fileSize ?? 0)
                        modified = target.contentModificationDate
                    } else if values.isRegularFile != true {
                        continue
                    }

                    if !sizeMatches(criteria, size) { continue }
                    if let modified, !dateMatches(criteria, modified) { continue }
                    if !text.accepts(path, cancel: cancel) { continue }
                    if cancel.isCancelled { return }

                    found(SearchHit(path: path, size: size, modified: modified))
                }

                // Reversed, so the first subfolder in the listing is the next one walked.
                stack.append(contentsOf: subfolders.reversed())
            }
        }
    }

    static func sizeMatches(_ criteria: SearchCriteria, _ size: Int64) -> Bool {
        switch criteria.sizeRule {
        case .atLeast: return size >= criteria.sizeBytes
        case .atMost: return size <= criteria.sizeBytes
        case .exactly: return size == criteria.sizeBytes
        case .any: return true
        }
    }

    static func dateMatches(_ criteria: SearchCriteria, _ modified: Date) -> Bool {
        if let after = criteria.modifiedAfter, modified < after { return false }
        if let before = criteria.modifiedBefore, modified > before { return false }
        return true
    }

    private struct FolderID: Hashable {
        let device: Int64
        let inode: UInt64
    }
}
