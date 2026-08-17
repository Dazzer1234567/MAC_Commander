import Foundation

enum TransferKind: Sendable {
    case copy, move

    var verb: String { self == .copy ? "Copying" : "Moving" }
}

struct TransferProgress {
    var title: String
    var current: String
    var completed: Int
    var total: Int

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

enum ConflictDecision {
    case overwrite, skip, keepBoth, cancel
}

struct PathPair: Sendable {
    let from: URL
    let to: URL
}

/// What a transfer actually managed to do, which is what makes it undoable.
struct TransferOutcome {
    var movedPairs: [PathPair] = []
    var createdCopies: [URL] = []
    var errors: [String] = []
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    let source: URL
    let destination: URL
}

/// Runs copy/move/trash operations off the main thread, pausing to ask the user
/// what to do whenever the destination already has a file of the same name.
@MainActor
final class TransferController: ObservableObject {
    @Published var progress: TransferProgress?
    @Published var conflict: ConflictRequest?

    private var decisionContinuation: CheckedContinuation<(ConflictDecision, Bool), Never>?
    private var blanketDecision: ConflictDecision?
    private var cancelled = false

    var isRunning: Bool { progress != nil }

    func cancel() {
        cancelled = true
        if conflict != nil { resolve(.cancel, applyToAll: true) }
    }

    func resolve(_ decision: ConflictDecision, applyToAll: Bool) {
        conflict = nil
        let continuation = decisionContinuation
        decisionContinuation = nil
        continuation?.resume(returning: (decision, applyToAll))
    }

    func run(kind: TransferKind, sources: [URL], destination: URL) async -> TransferOutcome {
        var outcome = TransferOutcome()
        guard !sources.isEmpty else { return outcome }
        cancelled = false
        blanketDecision = nil
        let fm = FileManager.default

        progress = TransferProgress(
            title: "\(kind.verb) \(sources.count) item\(sources.count == 1 ? "" : "s")…",
            current: "",
            completed: 0,
            total: sources.count
        )
        defer { progress = nil }

        for (index, source) in sources.enumerated() {
            if cancelled { break }
            progress?.completed = index
            progress?.current = source.lastPathComponent

            var target = destination.appendingPathComponent(source.lastPathComponent)

            // Copying a file into its own folder: silently make a numbered duplicate.
            if source.standardizedFileURL == target.standardizedFileURL {
                guard kind == .copy else { continue }
                target = Self.uniqueURL(for: target)
            } else if fm.fileExists(atPath: target.path) {
                let decision: ConflictDecision
                if let blanket = blanketDecision {
                    decision = blanket
                } else {
                    let (choice, applyToAll) = await askAboutConflict(source: source, destination: target)
                    if applyToAll { blanketDecision = choice }
                    decision = choice
                }

                switch decision {
                case .cancel:
                    cancelled = true
                    continue
                case .skip:
                    continue
                case .keepBoth:
                    target = Self.uniqueURL(for: target)
                case .overwrite:
                    // Trash rather than delete, so replacing a file is recoverable.
                    do {
                        try fm.trashItem(at: target, resultingItemURL: nil)
                    } catch {
                        outcome.errors.append("\(target.lastPathComponent): \(error.localizedDescription)")
                        continue
                    }
                }
            }

            let finalTarget = target
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager()
                    switch kind {
                    case .copy: try fm.copyItem(at: source, to: finalTarget)
                    case .move: try fm.moveItem(at: source, to: finalTarget)
                    }
                }.value
                switch kind {
                case .copy: outcome.createdCopies.append(finalTarget)
                case .move: outcome.movedPairs.append(PathPair(from: source, to: finalTarget))
                }
            } catch {
                outcome.errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        progress?.completed = sources.count
        return outcome
    }

    /// Each archive lands in its own folder beside the others, rather than
    /// spilling loose files into the destination.
    func extract(archives: [URL], intoParent parent: URL) async -> TransferOutcome {
        var outcome = TransferOutcome()
        guard !archives.isEmpty else { return outcome }
        cancelled = false

        progress = TransferProgress(
            title: "Extracting \(archives.count) archive\(archives.count == 1 ? "" : "s")…",
            current: "",
            completed: 0,
            total: archives.count
        )
        defer { progress = nil }

        for (index, archive) in archives.enumerated() {
            if cancelled { break }
            progress?.completed = index
            progress?.current = archive.lastPathComponent

            let target = Self.uniqueURL(
                for: parent.appendingPathComponent(ArchiveService.baseName(of: archive)))
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.extract(archive, into: target)
                }.value
                outcome.createdCopies.append(target)
            } catch {
                outcome.errors.append("\(archive.lastPathComponent): \(error.localizedDescription)")
            }
        }

        progress?.completed = archives.count
        return outcome
    }

    func trash(_ urls: [URL]) -> [String] {
        var errors: [String] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return errors
    }

    private func askAboutConflict(source: URL, destination: URL) async -> (ConflictDecision, Bool) {
        await withCheckedContinuation { continuation in
            decisionContinuation = continuation
            conflict = ConflictRequest(source: source, destination: destination)
        }
    }

    /// "report.pdf" -> "report 2.pdf", "report 3.pdf", …
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
