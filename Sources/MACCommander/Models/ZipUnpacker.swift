import Foundation

/// What the unpack dialog was told, a property to each of its boxes.
struct UnpackOptions: Sendable {
    /// Which files to take out, as masks: "*.txt;*.md", or "*.*" for all of them.
    var mask = "*.*"
    /// Files come out into the folders they were stored in. Without this they all land in
    /// the one folder, whatever folder they were in.
    var keepPaths = true
    /// What is there already is replaced without asking.
    var overwrite = false
    /// Each archive goes into a folder of its own, named after it.
    var ownFolder = false
}

/// A place inside an archive: the archive itself, and the folder within it. The top of the
/// archive is an empty `inside`.
struct ArchivePlace: Sendable {
    let archive: String
    let inside: String
}

/// One file to come out of an archive, and where it is going. `entry` is the name exactly
/// as the archive stores it.
struct ZipCopy: Sendable {
    let entry: String
    let to: String
    let size: Int64
}

/// Everything a copy out of an archive is going to do, worked out before any of it is done
/// so that what would be overwritten can be asked about first.
struct ZipPlan: Sendable {
    let from: ArchivePlace
    let files: [ZipCopy]
    let folders: [String]
    let refused: [String]

    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The files that are already there, and would be replaced.
    func clashes() -> [String] {
        files.filter { ZipUnpacker.isFile($0.to) }.map(\.to)
    }
}

struct ZipOutcome: Sendable {
    let copied: Int
    let skipped: Int
    let cancelled: Bool
    let failures: [String]
}

/// One archive's part in an unpack: where it is going, and what did not make the cut.
/// `dropped` are files whose names another file had already taken, once their folders
/// were left behind.
struct UnpackPlan: Sendable {
    let plan: ZipPlan
    let folder: String
    let dropped: [String]
}

/// Unpacks archives, after Total Commander's Unpack files: works out which files and where
/// they go, then takes them out with `bsdtar` - zip, tar and its kin, 7z, rar, iso, whatever
/// `ArchiveService.isArchive` takes. Everything comes out into a staging folder first and
/// is then put in place by the plan, so names are made safe, clashes are known up front,
/// and "path names off" can drop the folders.
enum ZipUnpacker {
    // MARK: - Where it goes

    /// Reads the folder that was typed. A relative one is taken from the folder on offer,
    /// and one inside an archive is refused, since nothing can be put into one.
    /// - Returns: the folder's full path, or why there cannot be one.
    static func resolve(_ typed: String?, folder: String) -> (folder: String?, error: String?) {
        var path = (typed ?? "").trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return (nil, "Say which folder to unpack into.") }

        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (folder as NSString).appendingPathComponent(path) }
        // "/out/" and "/out" are one folder
        path = (path as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        if path.split(separator: "/").contains(where: { $0.contains(":") || $0.contains("\0") }) {
            return (nil, "That is not a folder that can be made:\n\(path)")
        }
        if isFile(path) { return (nil, "That is a file, not a folder:\n\(path)") }
        if ArchiveService.locate(path) != nil {
            return (nil, "That is inside an archive, and nothing can be put into one from here.")
        }
        return (path, nil)
    }

    /// Everything at the top of an archive, which is what unpacking the whole of it asks for.
    static func everything(_ archive: ArchivePlace) throws -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for entry in try read(archive.archive) {
            guard let first = entry.path.split(separator: "/").first.map(String.init) else { continue }
            if seen.insert(first.lowercased()).inserted { names.append(first) }
        }
        return names
    }

    /// The folder an archive goes into when each has its own: its name, without ".zip",
    /// or ".tar.gz".
    static func ownFolderFor(_ target: String, from: ArchivePlace) -> String {
        (target as NSString).appendingPathComponent(ArchiveService.baseName(of: URL(fileURLWithPath: from.archive)))
    }

    // MARK: - What comes out

    /// Works out where everything would go, without writing anything.
    /// - Parameter names: what to take out, at the level of the archive `from` is at.
    static func plan(_ from: ArchivePlace, names: [String], target: String, options: UnpackOptions) throws -> UnpackPlan {
        let folder = options.ownFolder ? ownFolderFor(target, from: from) : target
        let plan = try copyPlan(from, names: names, into: folder)

        let mask = Mask(options.mask)
        var files = plan.files.filter { mask.matches(($0.to as NSString).lastPathComponent) }

        // Folders come along only for everything: with a mask, an empty folder is not one
        // of the files asked for, and one holding them is made on the way anyway.
        let folders = options.keepPaths && mask.matchesEverything ? plan.folders : []

        var dropped: [String] = []
        if !options.keepPaths {
            var taken: Set<String> = []
            var flat: [ZipCopy] = []
            for file in files {
                let to = (folder as NSString).appendingPathComponent((file.to as NSString).lastPathComponent)
                // two "readme.txt" from two folders cannot both be the one in this folder
                if taken.insert(to.lowercased()).inserted { flat.append(ZipCopy(entry: file.entry, to: to, size: file.size)) }
                else { dropped.append(file.entry) }
            }
            files = flat
        }

        return UnpackPlan(plan: ZipPlan(from: from, files: files, folders: folders, refused: plan.refused),
                          folder: folder, dropped: dropped)
    }

    /// Which entries are the things named, and where each lands in the folder: under its
    /// own name, with what is under it below that.
    static func copyPlan(_ from: ArchivePlace, names: [String], into target: String) throws -> ZipPlan {
        var target = target
        while target.count > 1 && target.hasSuffix("/") { target.removeLast() }

        let wanted = Set(names.compactMap { tidy($0)?.lowercased() })
        let prefix = from.inside.isEmpty ? "" : (tidy(from.inside) ?? "") + "/"
        var files: [ZipCopy] = []
        var folders: [String] = []
        var refused: [String] = []

        for entry in try read(from.archive) {
            guard let rest = under(entry.path, prefix: prefix), !rest.isEmpty else { continue }
            let slash = rest.firstIndex(of: "/")
            let top = slash.map { String(rest[..<$0]) } ?? rest
            guard wanted.contains(top.lowercased()) else { continue }

            let to = (target as NSString).appendingPathComponent(rest)

            // Belt and braces: the names were made safe when the archive was read, and this
            // is the check that what comes of them is still inside the place copied to.
            guard to.hasPrefix(target == "/" ? "/" : target + "/"), !to.split(separator: "/").contains("..") else {
                refused.append(entry.raw)
                continue
            }
            if entry.isFolder { folders.append(to) }
            else { files.append(ZipCopy(entry: entry.raw, to: to, size: entry.size)) }
        }
        return ZipPlan(from: from, files: files, folders: folders, refused: refused)
    }

    /// Whether an entry lies in this folder or below it, and what is left of its path if so.
    private static func under(_ path: String, prefix: String) -> String? {
        if prefix.isEmpty { return path }
        let lower = path.lowercased(), lowerPrefix = prefix.lowercased()
        // the folder's own entry
        if lower + "/" == lowerPrefix { return "" }
        guard lower.hasPrefix(lowerPrefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Unpacking

    /// Carries out the plans, an archive at a time, reporting to the one progress box as
    /// though they were a single job.
    static func unpack(_ plans: [UnpackPlan], overwrite: Bool, progress: ZipProgress? = nil) -> ZipOutcome {
        var copied = 0, skipped = 0
        var cancelled = false
        var failures = plans.flatMap { $0.dropped.map { "\($0): another file of that name is already coming out" } }
        let total = plans.reduce(0) { $0 + $1.plan.files.count }

        for plan in plans {
            if progress?.cancelRequested == true { cancelled = true; break }
            let outcome = extract(plan.plan, near: plan.folder, overwrite: overwrite, progress: progress, total: total)
            copied += outcome.copied
            skipped += outcome.skipped
            failures += outcome.failures
            if outcome.cancelled { cancelled = true; break }
        }
        return ZipOutcome(copied: copied, skipped: skipped, cancelled: cancelled, failures: failures)
    }

    /// Carries out one plan. A file that cannot be put in place is noted and the rest go
    /// on: one bad entry should not cost the others.
    /// - Parameters:
    ///   - near: the folder unpacked into, where the staging folder is made beside so
    ///     that putting things in place is a rename and not a second copy.
    ///   - overwrite: false leaves alone whatever is already there.
    static func extract(_ plan: ZipPlan, near: String, overwrite: Bool, progress: ZipProgress? = nil,
                        total: Int? = nil) -> ZipOutcome {
        let fm = FileManager.default
        let total = total ?? plan.files.count
        let archiveName = (plan.from.archive as NSString).lastPathComponent
        var failures = plan.refused.map { "\($0): not a safe path" }
        var copied = 0, skipped = 0
        var cancelled = false

        for folder in plan.folders {
            do { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            catch { failures.append("\((folder as NSString).lastPathComponent): \(ZipPacker.reason(error))") }
        }

        var wanted: [ZipCopy] = []
        for file in plan.files {
            if !overwrite && isFile(file.to) {
                skipped += 1
                progress?.started((file.to as NSString).lastPathComponent)
                progress?.finished(of: total)
            } else {
                wanted.append(file)
            }
        }
        guard !wanted.isEmpty else { return ZipOutcome(copied: 0, skipped: skipped, cancelled: false, failures: failures) }
        if progress?.cancelRequested == true { return ZipOutcome(copied: 0, skipped: skipped, cancelled: true, failures: failures) }

        let staging: URL
        do {
            try fm.createDirectory(atPath: near, withIntermediateDirectories: true)
            staging = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: URL(fileURLWithPath: near), create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MACCommander-unpack-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            failures.append("\((near as NSString).lastPathComponent): \(ZipPacker.reason(error))")
            return ZipOutcome(copied: 0, skipped: skipped, cancelled: false, failures: failures)
        }
        let list = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MACCommander-unpack-\(UUID().uuidString).list")
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: list)
        }

        // The names go to bsdtar as patterns, so what would be a wildcard is escaped, and
        // they are NUL-separated: a name may hold anything but that.
        var seen: Set<String> = []
        let patterns = wanted.map(\.entry).filter { seen.insert($0).inserted }.map(escape)
        do {
            try Data(patterns.joined(separator: "\0").appending("\0").utf8).write(to: list)
        } catch {
            failures.append("\(archiveName): \(ZipPacker.reason(error))")
            return ZipOutcome(copied: 0, skipped: skipped, cancelled: false, failures: failures)
        }

        let result = ZipTool.run("/usr/bin/bsdtar",
                                 ["-x", "-v", "-f", plan.from.archive, "-C", staging.path, "--null", "-T", list.path],
                                 progress: progress, lines: .errors) { line in
            // "x docs/guide.txt", said as each one comes out
            guard line.hasPrefix("x "), !line.hasSuffix("/") else { return }
            progress?.started((String(line.dropFirst(2)) as NSString).lastPathComponent)
            progress?.finished(of: total)
        }
        if result.cancelled {
            return ZipOutcome(copied: 0, skipped: skipped, cancelled: true, failures: failures)
        }

        let why = result.message.isEmpty
            ? "it is encrypted, damaged, or packed in a way this cannot read"
            : result.message
        let stagedAny = ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty == false
        if !stagedAny && result.status != 0 {
            failures.append("\(archiveName): \(why)")
            return ZipOutcome(copied: 0, skipped: skipped, cancelled: false, failures: failures)
        }

        for file in wanted {
            if progress?.cancelRequested == true { cancelled = true; break }
            let name = (file.to as NSString).lastPathComponent
            var stored = file.entry
            while stored.hasPrefix("./") { stored.removeFirst(2) }
            while stored.hasPrefix("/") { stored.removeFirst() }
            let staged = staging.appendingPathComponent(stored).path

            guard (try? fm.attributesOfItem(atPath: staged)) != nil else {
                failures.append("\(name): \(why)")
                continue
            }
            do {
                try fm.createDirectory(atPath: (file.to as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: file.to, isDirectory: &isDir) {
                    if isDir.boolValue { throw ZipToolError.failed("a folder of that name is in the way") }
                    if !overwrite { skipped += 1; continue }
                    try fm.removeItem(atPath: file.to)
                }
                try fm.moveItem(atPath: staged, toPath: file.to)
                copied += 1
            } catch {
                failures.append("\(name): \(ZipPacker.reason(error))")
            }
        }
        return ZipOutcome(copied: copied, skipped: skipped, cancelled: cancelled, failures: failures)
    }

    /// A name as a bsdtar pattern that matches only itself.
    private static func escape(_ name: String) -> String {
        var out = ""
        for c in name {
            if "\\*?[]".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// There, and not a folder.
    static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    // MARK: - What is in an archive

    /// `raw` is as stored, which is what the archive knows the entry by; `path` is tidied
    /// for use.
    struct Entry: Sendable {
        let raw: String
        let path: String
        let isFolder: Bool
        let size: Int64
    }

    /// The last archive read. Planning several things from one archive asks for the same
    /// list over and over, and a large one takes a moment to read.
    private static var last: (archive: String, stamp: String, entries: [Entry])?
    private static let gate = NSLock()

    static func read(_ archive: String) throws -> [Entry] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: archive)
        let stamp = "\((attributes?[.size] as? NSNumber)?.int64Value ?? -1)-\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"

        gate.lock()
        if let known = last, known.archive == archive, known.stamp == stamp { gate.unlock(); return known.entries }
        gate.unlock()

        let entries = try ZipTool.entries(of: archive).compactMap { entry -> Entry? in
            guard let path = tidy(entry.raw) else { return nil }
            return Entry(raw: entry.raw, path: path, isFolder: entry.isDirectory, size: entry.isDirectory ? 0 : entry.size)
        }

        gate.lock()
        last = (archive, stamp, entries)
        gate.unlock()
        return entries
    }

    /// A stored name made safe to use as a path. Nil for one that must not be used at all:
    /// a name that climbs out of its folder with ".." would land wherever it liked on disk.
    /// Backslashes are taken as the folder breaks a Windows program meant them as, and the
    /// characters macOS will not have in a name - the colon, which the Finder shows as a
    /// slash, and NUL - become "_".
    static func tidy(_ name: String) -> String? {
        var parts: [String] = []
        for part in name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            let clean = String(part.map { forbidden.contains($0) ? "_" : $0 })
            parts.append(clean.isEmpty ? "_" : clean)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static let forbidden: Set<Character> = [":", "\0"]

    // MARK: - Masks

    /// Masks as Find files reads them: "*.txt;*.md" takes either, and what follows a "|"
    /// is left out. A mask with no wildcard is a piece of the name to look for.
    struct Mask {
        private var include: [NSRegularExpression] = []
        private var exclude: [NSRegularExpression] = []

        /// True when the line named nothing, in which case every name matches.
        var matchesEverything: Bool { include.isEmpty }

        init(_ masks: String) {
            let bar = masks.firstIndex(of: "|")
            let wanted = bar.map { String(masks[..<$0]) } ?? masks
            let unwanted = bar.map { String(masks[masks.index(after: $0)...]) } ?? ""

            include = Self.split(wanted).compactMap(Self.compile)
            exclude = Self.split(unwanted).compactMap(Self.compile)

            // "*" and "*.*" are how everything is usually written, and mean the same as nothing.
            let trimmed = wanted.trimmingCharacters(in: .whitespaces)
            if include.count == 1 && (trimmed == "*" || trimmed == "*.*") { include.removeAll() }
        }

        func matches(_ name: String) -> Bool {
            let range = NSRange(name.startIndex..., in: name)
            if exclude.contains(where: { $0.firstMatch(in: name, range: range) != nil }) { return false }
            return matchesEverything || include.contains { $0.firstMatch(in: name, range: range) != nil }
        }

        private static func split(_ line: String) -> [String] {
            line.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        private static func compile(_ mask: String) -> NSRegularExpression? {
            var pattern = mask
            if !pattern.contains("*") && !pattern.contains("?") { pattern = "*" + pattern + "*" }
            var regex = "^"
            for c in pattern {
                switch c {
                case "*": regex += ".*"
                case "?": regex += "."
                default: regex += NSRegularExpression.escapedPattern(for: String(c))
                }
            }
            regex += "$"
            return try? NSRegularExpression(pattern: regex, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }
}
