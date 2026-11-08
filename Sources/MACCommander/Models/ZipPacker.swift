import Foundation

/// How hard the packer tries: Info-ZIP's -6, -1, -9 and -0.
enum PackLevel: String, CaseIterable, Sendable {
    case normal, fastest, best, stored

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .fastest: return "Fastest"
        case .best: return "Best, and slowest"
        case .stored: return "None, only stored"
        }
    }

    var flag: String {
        switch self {
        case .normal: return "-6"
        case .fastest: return "-1"
        case .best: return "-9"
        case .stored: return "-0"
        }
    }
}

/// What the pack dialog was told, a property to each of its boxes.
struct PackOptions: Sendable {
    /// A file from inside a folder keeps the path it had under it. Without this they all
    /// land at the top of the archive, whatever folder they came from.
    var keepPaths = true
    /// Folders go in with everything under them. Without this they are passed over, and
    /// only the files that were picked are packed.
    var recurse = true
    /// The originals are taken away once they are in the archive.
    var move = false
    /// An archive for each thing picked, named after it, in place of one for all.
    var separate = false
    var level: PackLevel = .normal
}

/// One file or empty folder to go into an archive, and what it is called there.
/// `entry` has forward slashes, and a closing one for a folder. `top` is the thing that
/// was picked, which this is or is somewhere under.
struct PackFile: Sendable {
    let source: String
    let entry: String
    let size: Int64
    let top: String
}

/// Something that was picked, or lay under it, and is not going in.
struct PackRefusal: Sendable {
    let name: String
    let why: String
    let top: String
}

/// Everything one archive is going to hold, worked out before any of it is written so that
/// an archive already there can be asked about first.
struct PackPlan: Sendable {
    let archive: String
    let sources: [String]
    let files: [PackFile]
    let folders: [PackFile]
    let refused: [PackRefusal]

    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Nothing to put in it, so no archive is made.
    var isEmpty: Bool { files.isEmpty && folders.isEmpty }

    /// There is a file of this name already, and it would be replaced.
    var clashes: Bool { FileManager.default.fileExists(atPath: archive) }
}

/// `made` are the archives that were written. `done` is what was picked and is now wholly
/// in an archive: all of it, with nothing under it left out. These are what a move may
/// take away.
struct PackOutcome: Sendable {
    let packed: Int
    let cancelled: Bool
    let made: [String]
    let done: [String]
    let failures: [String]
}

/// Where a long pack or unpack reports to. Called from whatever thread does the work, so
/// whatever stands behind it has to be safe to call from any of them.
protocol ZipProgress: AnyObject {
    var cancelRequested: Bool { get }
    func started(_ name: String)
    func finished(of total: Int)
}

/// Makes zip files, with Info-ZIP's `zip` that ships with macOS. An archive is written
/// under another name and given its own only once it is whole, so one that is called off
/// or fails leaves nothing behind, and one that was there already is left as it was.
enum ZipPacker {
    /// What an archive is called while it is being written.
    static let unfinished = ".packing"

    /// Kinds of archive that are not made here, so that asking for one can be refused by name.
    private static let otherArchives: Set<String> = [
        "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "arj", "lha", "lzh", "ace", "cab", "uc2",
        "tbz", "tbz2", "txz", "tzst", "lz4", "iso", "cpio", "dmg",
    ]

    // MARK: - Where it goes

    /// The name an archive is offered under: that of the one thing picked, or of the folder
    /// they are in when there are several. Without the extension.
    static func suggest(_ sources: [String], folder: String) -> String {
        let name = sources.count == 1 ? nameFor(sources[0]) : (trimmed(folder) as NSString).lastPathComponent
        // the top of the disk has no name of its own
        return name.trimmingCharacters(in: .whitespaces).isEmpty || name == "/" ? "Archive" : name
    }

    /// A folder's name, or a file's without its extension.
    static func nameFor(_ source: String) -> String {
        let path = trimmed(source)
        let name = (path as NSString).lastPathComponent
        if isDirectory(path) { return name }
        // ".gitignore" is all extension, and would leave nothing
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    private static func trimmed(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Reads what was typed for the archive and says which file is meant. A name alone goes
    /// in the folder on offer; a folder alone takes the name on offer; ".zip" is added where
    /// it was left off. Total Commander's "zip:" in front is taken as read.
    /// - Returns: the archive's full path, or why there cannot be one.
    static func resolve(_ typed: String?, folder: String, name: String) -> (archive: String?, error: String?) {
        var path = (typed ?? "").trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)

        // "zip:" names the packer: letters and digits before a colon, as Total Commander has it.
        if let colon = path.firstIndex(of: ":") {
            let packer = path[..<colon]
            if packer.count >= 2 && packer.allSatisfy({ $0.isLetter || $0.isNumber }) {
                guard packer.lowercased() == "zip" else { return (nil, "Only zip files can be made, not \"\(packer)\".") }
                path = path[path.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        guard !path.isEmpty else { return (nil, "Say what the zip file is to be called.") }

        let wantsFolder = path.hasSuffix("/")
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (folder as NSString).appendingPathComponent(path) }
        path = (path as NSString).standardizingPath

        if wantsFolder || isDirectory(path) { path = (path as NSString).appendingPathComponent(name + ".zip") }

        let ext = (path as NSString).pathExtension.lowercased()
        if otherArchives.contains(ext) { return (nil, "Only zip files can be made, not .\(ext).") }

        // "report.v2" is a name with a dot in it, and wants its .zip as much as any
        if ext != "zip" { path += ".zip" }

        // A colon is allowed underneath, but the Finder shows it as a slash and nothing
        // else expects one in a name.
        if path.split(separator: "/").contains(where: { $0.contains(":") || $0.contains("\0") }) {
            return (nil, "That is not a path a file can have:\n\(path)")
        }

        if ArchiveService.locate((path as NSString).deletingLastPathComponent) != nil {
            return (nil, "That is inside an archive, and nothing can be put into one from here.")
        }
        return (path, nil)
    }

    // MARK: - What goes in

    /// Works out what each archive would hold, without writing anything. One plan, unless
    /// an archive was asked for each thing picked: then one for each, in the folder the
    /// archive was to go in and named after the thing itself.
    static func plan(_ sources: [String], archive: String, options: PackOptions) -> [PackPlan] {
        guard options.separate else { return [planOne(sources, archive: archive, options: options)] }

        let folder = (archive as NSString).deletingLastPathComponent
        var taken: Set<String> = []
        var plans: [PackPlan] = []

        for source in sources {
            let name = nameFor(source)
            var path = (folder as NSString).appendingPathComponent(name + ".zip")
            // "notes.txt" and "notes.doc" would both be notes.zip
            var n = 2
            while !taken.insert(path.lowercased()).inserted {
                path = (folder as NSString).appendingPathComponent("\(name) (\(n)).zip")
                n += 1
            }
            plans.append(planOne([source], archive: path, options: options))
        }
        return plans
    }

    private static func planOne(_ sources: [String], archive: String, options: PackOptions) -> PackPlan {
        var files: [PackFile] = []
        var folders: [PackFile] = []
        var refused: [PackRefusal] = []
        // Told apart without case, as the disk they come back out onto usually does.
        var names: Set<String> = []
        var tops: [String] = []
        let fm = FileManager.default

        func addFile(_ path: String, entry: String, top: String) {
            let name = (path as NSString).lastPathComponent

            // Packing a folder into itself would otherwise reach the archive half written,
            // and try to put it inside itself.
            if same(path, archive) || same(path, archive + unfinished) {
                refused.append(PackRefusal(name: name, why: "it is the zip file being made", top: top))
                return
            }
            // zip is handed its names a line at a time
            if path.contains("\n") || path.contains("\r") {
                refused.append(PackRefusal(name: name, why: "a name with a line break in it cannot be packed", top: top))
                return
            }
            guard names.insert(entry.lowercased()).inserted else {
                refused.append(PackRefusal(name: name, why: "a file of that name is already going in", top: top))
                return
            }
            let size = (try? fm.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath)[.size] as? NSNumber)?.int64Value ?? 0
            files.append(PackFile(source: path, entry: entry, size: size, top: top))
        }

        func walk(_ folder: String, prefix: String, top: String) {
            let inside: [String]
            do {
                inside = try fm.contentsOfDirectory(atPath: folder).sorted()
            } catch {
                refused.append(PackRefusal(name: (folder as NSString).lastPathComponent,
                                           why: reason(error), top: top))
                return
            }

            // An empty folder has no file to bring its name along, so it gets an entry of
            // its own - where paths are kept at all.
            if inside.isEmpty && options.keepPaths && names.insert(prefix.lowercased() + "/").inserted {
                folders.append(PackFile(source: folder, entry: prefix + "/", size: 0, top: top))
            }

            for name in inside {
                let path = (folder as NSString).appendingPathComponent(name)
                switch kind(of: path) {
                case .file:
                    addFile(path, entry: options.keepPaths ? prefix + "/" + name : name, top: top)
                case .folderLink:
                    // A link can lead anywhere, back to a folder above it included.
                    refused.append(PackRefusal(name: name, why: "it is a link to another folder, and is not followed", top: top))
                case .folder:
                    walk(path, prefix: prefix + "/" + name, top: top)
                case .other(let why):
                    refused.append(PackRefusal(name: name, why: why, top: top))
                }
            }
        }

        for source in sources {
            let top = trimmed(source)
            tops.append(top)
            let name = (top as NSString).lastPathComponent

            // What was picked is gone into even when it is a link: it was asked for by name.
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: top, isDirectory: &isDir) {
                refused.append(PackRefusal(name: name, why: "it is no longer there", top: top))
            } else if isDir.boolValue {
                if options.recurse { walk(top, prefix: name, top: top) }
            } else if case .other(let why) = kind(of: top) {
                refused.append(PackRefusal(name: name, why: why, top: top))
            } else {
                addFile(top, entry: name, top: top)
            }
        }

        return PackPlan(archive: archive, sources: tops, files: files, folders: folders, refused: refused)
    }

    private enum Kind { case file, folder, folderLink, other(String) }

    private static func kind(of path: String) -> Kind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return .other("it could not be read") }
        switch type {
        case .typeRegular: return .file
        case .typeDirectory: return .folder
        case .typeSymbolicLink:
            // a link to a file brings the file's contents; one that leads nowhere is
            // tried all the same, and reported when it cannot be read
            return isDirectory(path) ? .folderLink : .file
        default: return .other("it is not an ordinary file")
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    /// A folder, or a link to one.
    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Packing

    /// Carries out the plans, an archive at a time. A file that cannot be read is noted and
    /// the rest go on; an archive that fails takes nothing with it, since one holding half
    /// a file looks like the real thing.
    static func pack(_ plans: [PackPlan], level: PackLevel, progress: ZipProgress? = nil) -> PackOutcome {
        var failures: [String] = []
        var made: [String] = []
        var done: [String] = []
        var packed = 0
        var cancelled = false
        let total = plans.reduce(0) { $0 + $1.files.count }

        for plan in plans {
            if progress?.cancelRequested == true { cancelled = true; break }

            failures += plan.refused.map { "\($0.name): \($0.why)" }

            if !plan.isEmpty {
                var spoiled = Set(plan.refused.map(\.top))
                let went = write(plan, level: level, progress: progress, total: total,
                                 failures: &failures, spoiled: &spoiled, cancelled: &cancelled)
                if let went {
                    made.append(plan.archive)
                    packed += went.filter { !$0.entry.hasSuffix("/") }.count
                    done += plan.sources.filter { top in !spoiled.contains(top) && went.contains { $0.top == top } }
                }
            }
            if cancelled { break }
        }
        return PackOutcome(packed: packed, cancelled: cancelled, made: made, done: done, failures: failures)
    }

    /// Writes one archive.
    /// - Parameter spoiled: what was picked and has had something under it left out. Added to.
    /// - Returns: what is in the archive, or nil when no archive came of it.
    private static func write(_ plan: PackPlan, level: PackLevel, progress: ZipProgress?, total: Int,
                              failures: inout [String], spoiled: inout Set<String>,
                              cancelled: inout Bool) -> [PackFile]? {
        let fm = FileManager.default
        let unfinished = plan.archive + Self.unfinished
        let archiveName = (plan.archive as NSString).lastPathComponent
        var whole = false
        var ours = false

        defer {
            if ours && !whole { try? fm.removeItem(atPath: unfinished) }
        }

        do {
            try fm.createDirectory(atPath: (plan.archive as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            // One left from an earlier attempt would be added to, not started afresh.
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: unfinished, isDirectory: &isDir) {
                if isDir.boolValue { throw ZipToolError.failed("\(unfinished) is in the way") }
                try fm.removeItem(atPath: unfinished)
            }
        } catch {
            failures.append("\(archiveName): it was not made. \(reason(error))")
            return nil
        }

        // Tried before zip is: a file that cannot be read is then named with the reason,
        // and the others still go in.
        var going: [PackFile] = []
        for file in plan.files {
            if let handle = FileHandle(forReadingAtPath: file.source) {
                try? handle.close()
                going.append(file)
            } else {
                let why = errno == 0 ? "it could not be read" : String(cString: strerror(errno))
                failures.append("\((file.source as NSString).lastPathComponent): \(why)")
                spoiled.insert(file.top)
            }
        }

        // zip names each entry by the path it is handed, so it is run from the folder the
        // entries are named from. Paths kept: the folder above what was picked, usually one
        // for all. Paths left off: every file by its full path, and -j to drop the folders.
        var runs: [(folder: String?, names: [String])] = []
        if plan.folders.isEmpty && going.isEmpty { return nil }
        let keepPaths = plan.folders.count > 0 || going.contains { $0.entry.contains("/") }
        if keepPaths {
            var order: [String] = []
            var byBase: [String: [String]] = [:]
            for item in plan.folders + going {
                let entry = item.entry.hasSuffix("/") ? String(item.entry.dropLast()) : item.entry
                var base = String(item.source.dropLast(entry.count))
                while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
                if byBase[base] == nil { order.append(base) }
                byBase[base, default: []].append(entry)
            }
            runs = order.map { ($0, byBase[$0] ?? []) }
        } else {
            runs = [(nil, going.map(\.source))]
        }

        var lastStatus: Int32 = 0
        var lastMessage = ""
        for run in runs {
            if progress?.cancelRequested == true { cancelled = true; break }
            var arguments = [level.flag, "-nw"]
            if run.folder == nil { arguments.append("-j") }
            arguments += [unfinished, "-@"]
            ours = true
            let names = run.names.joined(separator: "\n") + "\n"
            let result = ZipTool.run("/usr/bin/zip", arguments, in: run.folder, input: Data(names.utf8),
                                     progress: progress, lines: .output) { line in
                // "  adding: docs/guide.txt (deflated 12%)"
                guard let at = line.range(of: "adding: ") else { return }
                var name = String(line[at.upperBound...])
                if let paren = name.range(of: " (", options: .backwards) { name = String(name[..<paren.lowerBound]) }
                if name.hasSuffix("/") { return }
                progress?.started((name as NSString).lastPathComponent)
                progress?.finished(of: total)
            }
            if result.cancelled { cancelled = true; break }
            // 18 is some files not read, which the reading back below sorts out
            if result.status != 0 && result.status != 18 && result.status != 12 {
                lastStatus = result.status
                lastMessage = result.message
                break
            }
        }

        if cancelled { return nil }
        if lastStatus != 0 {
            failures.append("\(archiveName): it was not made. \(lastMessage.isEmpty ? "zip stopped with code \(lastStatus)" : lastMessage)")
            return nil
        }
        var went = plan.folders + going

        // Read back before it is trusted: what a move takes away afterwards is gone. zip
        // makes nothing at all when every file has gone since the plan was made.
        let found: [String: (size: Int64, isDirectory: Bool)]
        do {
            found = fm.fileExists(atPath: unfinished) ? try ZipTool.contents(of: unfinished) : [:]
        } catch {
            failures.append("\(archiveName): it was not made. It could not be read back: \(reason(error))")
            return nil
        }
        went.removeAll { file in
            let key = file.entry.hasSuffix("/") ? String(file.entry.dropLast()) : file.entry
            let now = file.entry.hasSuffix("/") ? 0
                : (try? fm.attributesOfItem(atPath: (file.source as NSString).resolvingSymlinksInPath)[.size] as? NSNumber)?.int64Value ?? -1
            guard let entry = found[key], entry.isDirectory == file.entry.hasSuffix("/"),
                  entry.isDirectory || entry.size == now else {
                failures.append("\((file.source as NSString).lastPathComponent): it did not reach the zip file whole")
                spoiled.insert(file.top)
                return true
            }
            return false
        }

        // Nothing went in after all, every file having been refused on the way.
        if went.isEmpty { return nil }

        // rename() replaces one that is there in a single step: never a moment with neither.
        guard rename(unfinished, plan.archive) == 0 else {
            failures.append("\(archiveName): it was not made. \(String(cString: strerror(errno)))")
            return nil
        }
        whole = true
        return went
    }

    static func reason(_ error: Error) -> String {
        if let tool = error as? ZipToolError { return tool.localizedDescription }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return ns.localizedDescription
    }
}

enum ZipToolError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Runs the command-line tools that do the packing and unpacking: zip, and bsdtar, which
/// reads every kind of archive `ArchiveService` knows.
enum ZipTool {
    enum Stream { case output, errors }

    struct Result {
        let status: Int32
        /// The first thing the tool complained of, without its own name in front.
        let message: String
        let cancelled: Bool
    }

    /// Runs a tool to the end, or until the progress says stop. Each line of the chosen
    /// stream is handed over as it comes, for reporting how far it has got.
    static func run(_ tool: String, _ arguments: [String], in folder: String? = nil, input: Data? = nil,
                    progress: ZipProgress? = nil, lines: Stream = .output,
                    line onLine: ((String) -> Void)? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        // A program started from the Finder has no language set, and both tools would then
        // spoil every name that is not plain ASCII.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        do { try process.run() } catch {
            return Result(status: -1, message: error.localizedDescription, cancelled: false)
        }

        let lock = NSLock()
        var errors = Data()
        let group = DispatchGroup()

        func drain(_ handle: FileHandle, _ stream: Stream) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if stream == .errors { lock.lock(); errors.append(chunk); lock.unlock() }
                    guard stream == lines, let onLine else { continue }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                if stream == lines, let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                group.leave()
            }
        }
        drain(out.fileHandleForReading, .output)
        drain(err.fileHandleForReading, .errors)

        if let input {
            // Written from aside: the tool may answer before it has read it all.
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var cancelled = false
        while process.isRunning {
            if !cancelled, progress?.cancelRequested == true {
                cancelled = true
                process.terminate()
            }
            usleep(30_000)
        }
        process.waitUntilExit()
        group.wait()

        lock.lock()
        let complaint = String(decoding: errors, as: UTF8.self)
        lock.unlock()
        let first = complaint.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("x ") } ?? ""
        let message = first.replacingOccurrences(of: "bsdtar: ", with: "").replacingOccurrences(of: "zip error: ", with: "")
        return Result(status: process.terminationStatus, message: message, cancelled: cancelled)
    }

    /// One entry as an archive has it.
    struct Entry {
        /// Exactly as stored, which is what the archive knows it by.
        let raw: String
        let isDirectory: Bool
        let size: Int64
    }

    /// Every entry of an archive, read with `bsdtar -tv` without unpacking any of it.
    static func entries(of archive: String) throws -> [Entry] {
        var lines: [String] = []
        let result = run("/usr/bin/bsdtar", ["-tvf", archive]) { lines.append($0) }
        guard result.status == 0 else {
            throw ZipToolError.failed(result.message.isEmpty ? "it could not be read" : result.message)
        }
        return lines.compactMap(parse)
    }

    /// `-rw-r--r--  0 daz  staff  9 Mar  5  2024 docs/guide.txt`: mode, links, owner,
    /// group, size and a three-part date, then the name, which may have spaces in it.
    static func parse(_ line: String) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9 else { return nil }
        let mode = fields[0]
        var name = String(fields[8])
        if mode.hasPrefix("l"), let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        if mode.hasPrefix("h"), let link = name.range(of: " link to ") { name = String(name[..<link.lowerBound]) }
        guard !name.isEmpty else { return nil }
        return Entry(raw: name, isDirectory: mode.hasPrefix("d") || name.hasSuffix("/"), size: Int64(fields[4]) ?? 0)
    }

    /// The entries by name, closing slashes and "./" taken off, for checking an archive
    /// just written holds what it should.
    static func contents(of archive: String) throws -> [String: (size: Int64, isDirectory: Bool)] {
        var found: [String: (size: Int64, isDirectory: Bool)] = [:]
        for entry in try entries(of: archive) {
            var name = entry.raw
            if name.hasPrefix("./") { name.removeFirst(2) }
            while name.hasSuffix("/") { name.removeLast() }
            if found[name] == nil { found[name] = (entry.size, entry.isDirectory) }
        }
        return found
    }
}
