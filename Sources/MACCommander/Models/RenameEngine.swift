import Foundation

enum LetterCase: Int, CaseIterable {
    case unchanged, lower, upper, firstUpper, titleCase

    /// As the dialog's menu lists them.
    var label: String {
        switch self {
        case .unchanged: return "Leave as is"
        case .lower: return "lower case"
        case .upper: return "UPPER CASE"
        case .firstUpper: return "First letter upper"
        case .titleCase: return "Title Case"
        }
    }
}

enum RenameStatus {
    /// Will be renamed.
    case ok
    /// The mask produced the name it already has.
    case unchanged
    /// Two entries in this batch want the same name.
    case duplicate
    /// Something else on disk already has that name.
    case exists
    /// Empty, or contains characters a filename cannot hold.
    case invalid
}

struct RenameOptions: Equatable {
    var nameMask = "[N]"
    var extensionMask = "[E]"

    var searchFor = ""
    var replaceWith = ""
    var caseSensitive = false
    var useRegex = false

    var letterCase: LetterCase = .unchanged

    var counterStart = 1
    var counterStep = 1
    var counterDigits = 1
}

/// One row of the preview: where a file is now and what it would become.
struct RenamePlan {
    let path: String
    let oldName: String
    let newName: String
    var status: RenameStatus

    var willRename: Bool { status == .ok }
}

/// One finished batch: how many went through, what went wrong, and how to put it back.
struct RenameOutcome {
    let renamed: Int
    let errors: [String]
    let undo: [(from: String, to: String)]
}

/// Builds new filenames from a mask, in the style of Total Commander's multi-rename tool.
/// Deliberately free of UI so the placeholder rules can be tested directly.
enum RenameEngine {
    /// Produces the preview for a whole selection, including conflict detection.
    static func buildPlan(_ paths: [String], _ options: RenameOptions) -> [RenamePlan] {
        // Counters advance per file, in the order the list is shown.
        let plans = paths.enumerated().map { index, path in
            RenamePlan(path: path, oldName: fileName(path),
                       newName: buildName(path, index: index, options), status: .ok)
        }
        return classify(plans)
    }

    /// Applies the masks to one file. Public so the dialog can preview a single row.
    static func buildName(_ path: String, index: Int, _ options: RenameOptions) -> String {
        let (stem, ext) = split(fileName(path))
        let context = Context(path: path, stem: stem, ext: ext, index: index, options: options)

        let name = applyCase(expand(options.nameMask, context), options.letterCase)
        let newExt = expand(options.extensionMask, context)

        let combined = newExt.isEmpty ? name : "\(name).\(newExt)"
        return applySearchReplace(combined, options).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Names

    private static func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// Name and extension, split at the last dot. A leading dot is not an extension - a
    /// dotfile such as ".gitignore" is all name, as the file list shows it - and neither is
    /// a trailing one, so "notes." keeps its dot through the default mask.
    private static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    // MARK: - Placeholders

    private struct Context {
        let path: String
        let stem: String
        let ext: String
        let index: Int
        let options: RenameOptions
    }

    private static func expand(_ mask: String, _ context: Context) -> String {
        if mask.isEmpty { return "" }

        // Only asked for when a date placeholder needs it: it is a trip to the disk.
        var timestamp: Date?
        func stamp(_ format: String) -> String {
            if timestamp == nil { timestamp = writeTime(context.path) }
            return formatter(format).string(from: timestamp!)
        }

        var result = ""
        var rest = mask[...]
        while let open = rest.firstIndex(of: "[") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "]") else {
                rest = rest[open...]
                break
            }
            let token = rest[open...close]
            let body = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]

            // "[]" is nothing to expand; leave the brackets as typed.
            guard let kind = body.first else { result += token; continue }
            let argument = String(body.dropFirst())

            switch kind {
            case "N": result += slice(context.stem, argument)
            case "E": result += slice(context.ext, argument)
            case "C": result += counter(argument, context.index, context.options)
            case "P": result += ancestorName(context.path, levels: 1)
            case "G": result += ancestorName(context.path, levels: 2)
            case "Y": result += stamp("yyyy")
            case "M": result += stamp("MM")
            case "D": result += stamp("dd")
            case "h": result += stamp("HH")
            case "m": result += stamp("mm")
            case "s": result += stamp("ss")
            case "d": result += stamp("yyyy-MM-dd")
            case "t": result += stamp("HH-mm-ss")
            default: result += token      // unknown placeholder passes through untouched
            }
        }
        return result + rest
    }

    /// Whole numbers as .NET reads them, which forgives surrounding spaces.
    private static func number(_ text: Substring) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    /// The character-range forms, all 1-based like Total Commander:
    /// bare = whole string, "2" = one character, "2-5" = a range, "2-" = to the end,
    /// "2,5" = five characters from position 2. Out-of-range values clamp rather than fail.
    private static func slice(_ value: String, _ argument: String) -> String {
        if argument.isEmpty { return value }
        if value.isEmpty { return "" }

        if let comma = argument.firstIndex(of: ","), comma != argument.startIndex {
            guard let from = number(argument[..<comma]),
                  let count = number(argument[argument.index(after: comma)...]) else { return value }
            return substring(value, from, count)
        }

        if let dash = argument.firstIndex(of: "-"), dash != argument.startIndex {
            guard let from = number(argument[..<dash]) else { return value }
            let tail = argument[argument.index(after: dash)...]
            if tail.isEmpty { return substring(value, from, Int.max) }
            guard let to = number(tail) else { return value }
            return substring(value, from, to - from + 1)
        }

        guard let single = number(argument[...]) else { return value }
        return substring(value, single, 1)
    }

    private static func substring(_ value: String, _ oneBasedStart: Int, _ count: Int) -> String {
        let start = max(0, oneBasedStart - 1)
        if start >= value.count || count <= 0 { return "" }
        return String(value.dropFirst(start).prefix(count))
    }

    /// "[C]" uses the dialog's counter settings. Inline forms override them:
    /// "[C10]" starts at 10, "[C10+2]" steps by 2, "[C10+2:3]" pads to 3 digits.
    private static func counter(_ argument: String, _ index: Int, _ options: RenameOptions) -> String {
        var start = options.counterStart
        var step = options.counterStep
        var digits = options.counterDigits

        if !argument.isEmpty {
            var rest = argument[...]

            if let colon = rest.firstIndex(of: ":") {
                if let d = number(rest[rest.index(after: colon)...]) { digits = d }
                rest = rest[..<colon]
            }

            if let plus = rest.firstIndex(of: "+") {
                if let st = number(rest[rest.index(after: plus)...]) { step = st }
                rest = rest[..<plus]
            }

            if !rest.isEmpty, let s = number(rest) { start = s }
        }

        // Padded like .NET's "000" format: the sign sits outside the zeros. Capped so a
        // stray keystroke cannot ask for a name thousands of zeros long.
        let (value, overflow) = start.addingReportingOverflow(index.multipliedReportingOverflow(by: step).partialValue)
        let shown = overflow ? start : value
        let magnitude = String(shown.magnitude)
        let width = min(max(1, digits), 64)
        let padded = String(repeating: "0", count: max(0, width - magnitude.count)) + magnitude
        return shown < 0 ? "-" + padded : padded
    }

    /// The parent's name for 1, the grandparent's for 2. The root of the disk has no name.
    private static func ancestorName(_ path: String, levels: Int) -> String {
        var dir = (path as NSString).deletingLastPathComponent
        for _ in 1..<levels where !dir.isEmpty && dir != "/" {
            dir = (dir as NSString).deletingLastPathComponent
        }
        if dir.isEmpty || dir == "/" { return "" }
        return (dir as NSString).lastPathComponent
    }

    private static func writeTime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// Fixed-pattern formatters in local time, as the file list shows its dates.
    private static func formatter(_ format: String) -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let made = formatters[format] { return made }
        let made = DateFormatter()
        made.locale = Locale(identifier: "en_US_POSIX")
        made.dateFormat = format
        formatters[format] = made
        return made
    }

    // MARK: - Post-processing

    private static func applyCase(_ value: String, _ mode: LetterCase) -> String {
        guard let first = value.first else { return value }

        switch mode {
        case .lower:
            return value.lowercased()
        case .upper:
            return value.uppercased()
        case .firstUpper:
            return first.uppercased() + value.dropFirst().lowercased()
        case .titleCase:
            var result = ""
            var atStart = true
            for c in value {
                result += atStart ? c.uppercased() : c.lowercased()
                atStart = !(c.isLetter || c.isNumber)
            }
            return result
        case .unchanged:
            return value
        }
    }

    private static func applySearchReplace(_ value: String, _ options: RenameOptions) -> String {
        if options.searchFor.isEmpty { return value }

        if !options.useRegex {
            return value.replacingOccurrences(
                of: options.searchFor, with: options.replaceWith,
                options: options.caseSensitive ? [.literal] : [.literal, .caseInsensitive])
        }

        // A half-typed regular expression fails to compile; leave the name alone.
        guard let regex = try? NSRegularExpression(
            pattern: options.searchFor,
            options: options.caseSensitive ? [] : [.caseInsensitive]) else { return value }

        let whole = value as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: value, range: NSRange(location: 0, length: whole.length)) {
            result += whole.substring(with: NSRange(location: last, length: match.range.location - last))
            result += substitute(options.replaceWith, match, in: whole, pattern: regex.pattern)
            last = match.range.location + match.range.length
        }
        return result + whole.substring(from: last)
    }

    /// Fills in a replacement written the .NET way, as DAZ Commander takes it: "$1" and
    /// "${name}" for groups, "$0" or "$&" for the whole match, "$$" for a dollar sign.
    /// NSRegularExpression's own templates differ (no names, and "\" escapes), so the
    /// replacement is expanded by hand rather than passed through.
    private static func substitute(_ template: String, _ match: NSTextCheckingResult, in source: NSString,
                                   pattern: String) -> String {
        func group(_ range: NSRange) -> String {
            range.location == NSNotFound ? "" : source.substring(with: range)
        }

        var out = ""
        var rest = template[...]
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[..<dollar]
            let after = rest[rest.index(after: dollar)...]

            if after.first == "$" {
                out += "$"
                rest = after.dropFirst()
            } else if after.first == "&" {
                out += group(match.range)
                rest = after.dropFirst()
            } else if after.first == "{", let close = after.firstIndex(of: "}") {
                let name = String(after[after.index(after: after.startIndex)..<close])
                if let n = Int(name), n >= 0, n < match.numberOfRanges {
                    out += group(match.range(at: n))
                } else if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                          pattern.contains("(?<\(name)>") {
                    // Checked against the pattern first: asking for a name it lacks raises.
                    out += group(match.range(withName: name))
                } else {
                    out += "$" + after[...close]
                }
                rest = after[after.index(after: close)...]
            } else if let digit = after.first, digit.isASCII, digit.isNumber {
                // The longest run of digits that still names a group, as .NET reads it.
                let digits = after.prefix(while: { $0.isASCII && $0.isNumber })
                var used = digits.count
                while used > 0, (Int(digits.prefix(used)) ?? Int.max) >= match.numberOfRanges { used -= 1 }
                if used == 0 {
                    out += "$"
                    rest = after
                } else {
                    out += group(match.range(at: Int(digits.prefix(used))!))
                    rest = after.dropFirst(used)
                }
            } else {
                out += "$"
                rest = after
            }
        }
        return out + rest
    }

    // MARK: - Conflicts

    /// Why a name cannot be a file's name on the Mac: "/" separates paths, ":" is how the
    /// Finder shows a "/", and "." and ".." are taken.
    static func isInvalidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || name == "." || name == ".."
            || name.contains("/") || name.contains(":") || name.contains("\0")
    }

    /// APFS compares names without regard to case, so the batch does too.
    private static func key(_ path: String) -> String { path.lowercased() }

    private static func classify(_ input: [RenamePlan]) -> [RenamePlan] {
        var plans = input
        // Names claimed by this batch, so two files cannot be sent to the same place.
        var claimed = Set<String>()

        for i in plans.indices {
            let plan = plans[i]
            var status = RenameStatus.ok

            if isInvalidName(plan.newName) {
                status = .invalid
            } else if plan.newName == plan.oldName {
                status = .unchanged
            } else {
                let target = ((plan.path as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent(plan.newName)

                if claimed.contains(key(target)) {
                    status = .duplicate
                } else if existsOnDisk(target, besides: plan.path) {
                    // A file only in the way because it is about to move counts as free.
                    let blockerMoves = plans.indices.contains { j in
                        j != i && key(plans[j].path) == key(target) && plans[j].newName != plans[j].oldName
                    }
                    if !blockerMoves { status = .exists }
                }

                if status == .ok { claimed.insert(key(target)) }
            }

            plans[i].status = status
        }

        return plans
    }

    private static func existsOnDisk(_ candidate: String, besides own: String) -> Bool {
        // Only the case is changing: the "other" file is this one.
        if key(candidate) == key(own) { return false }
        return FileManager.default.fileExists(atPath: candidate)
    }

    // MARK: - Execution

    /// Renames in two passes through temporary names, so a batch can swap names round
    /// (a to b, b to a) without one rename standing on another.
    static func apply(_ plans: [RenamePlan]) -> RenameOutcome {
        var errors: [String] = []
        var undo: [(from: String, to: String)] = []
        var staged: [(temp: String, final: String, original: String)] = []

        for plan in plans where plan.willRename {
            let directory = (plan.path as NSString).deletingLastPathComponent
            let temp = (directory as NSString).appendingPathComponent(
                "~mac\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).tmp")
            do {
                try move(plan.path, temp)
                staged.append((temp, (directory as NSString).appendingPathComponent(plan.newName), plan.path))
            } catch {
                errors.append("\(plan.oldName): \(reason(error))")
            }
        }

        for (temp, final, original) in staged {
            do {
                try move(temp, final)
                undo.append((final, original))
            } catch {
                errors.append("\((final as NSString).lastPathComponent): \(reason(error))")
                try? move(temp, original)      // if even that fails, the temp is left for the user to find
            }
        }

        return RenameOutcome(renamed: undo.count, errors: errors, undo: undo)
    }

    /// Puts a completed batch back, newest first.
    static func revert(_ undo: [(from: String, to: String)]) -> RenameOutcome {
        var errors: [String] = []
        var done = 0

        for (from, to) in undo.reversed() {
            do {
                try move(from, to)
                done += 1
            } catch {
                errors.append("\((from as NSString).lastPathComponent): \(reason(error))")
            }
        }

        return RenameOutcome(renamed: done, errors: errors, undo: [])
    }

    /// Fails rather than replaces when the destination is taken, as a rename should.
    private static func move(_ from: String, _ to: String) throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    /// The underlying reason, without Cocoa's "couldn't be moved because" wrapping.
    private static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.localizedDescription
        }
        return ns.localizedDescription
    }
}
