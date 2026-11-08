import Foundation
import SwiftUI

enum TransferKind: Sendable {
    case copy, move

    var verb: String { self == .copy ? "Copying" : "Moving" }
}

enum ConflictDecision {
    case overwrite, skip, keepBoth, cancel
}

struct PathPair: Sendable {
    let from: URL
    let to: URL
}

/// What an operation actually managed to do, which is what makes it undoable.
struct TransferOutcome {
    var movedPairs: [PathPair] = []
    var createdCopies: [URL] = []
    var errors: [String] = []
    var cancelled = false
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    let source: URL
    let destination: URL
}

/// One long operation: a copy, move, delete, pack or unpack. It shows a small box in the
/// bottom-right corner of the window, but only once it has run for 0.4 seconds - a quick
/// one shows nothing at all.
@MainActor
final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let verb: String
    @Published var item = ""
    @Published var done = 0
    @Published var fraction: Double = 0
    @Published var cancelRequested = false
    /// Where the box has been dragged to, by its title.
    @Published var offset: CGSize = .zero

    init(verb: String) { self.verb = verb }

    var title: String {
        cancelRequested ? "\(verb) - stopping..." : "\(verb)  \(Int((fraction * 100).rounded()))%"
    }

    var countText: String { "\(Listing.plural(done, "item")) done" }

    /// Called from the operation as it goes; cheap enough to call per file.
    func started(_ name: String) { item = name }

    func finished(of total: Int) {
        done += 1
        fraction = total == 0 ? 1 : min(1, Double(done) / Double(total))
    }
}

/// The boxes on screen, by the slot each fills, counting up from the bottom.
@MainActor
final class JobCenter: ObservableObject {
    @Published private(set) var slots: [Job?] = []

    /// How many boxes have appeared so far. Taken before an operation: if it has moved by
    /// the end, the operation went to the background and the user may well have moved on,
    /// so the cursor should be left where they put it.
    private(set) var mark = 0

    private static let showAfter: TimeInterval = 0.4
    private var finished: Set<UUID> = []

    func start(_ verb: String) -> Job {
        let job = Job(verb: verb)
        DispatchQueue.main.asyncAfter(deadline: .now() + JobCenter.showAfter) { [weak self, weak job] in
            guard let self, let job, !self.finished.contains(job.id) else { return }
            if let free = self.slots.firstIndex(where: { $0 == nil }) { self.slots[free] = job }
            else { self.slots.append(job) }
            self.mark += 1
        }
        return job
    }

    func finish(_ job: Job) {
        finished.insert(job.id)
        if let index = slots.firstIndex(where: { $0?.id == job.id }) { slots[index] = nil }
        // trailing empty slots are given back, so the next box starts at the bottom again
        while let last = slots.last, last == nil { slots.removeLast() }
    }

    func appeared(since mark: Int) -> Bool { self.mark != mark }
}

/// Copies, moves and deletes, off the main thread, several at once if need be. Pauses to
/// ask when the destination already has something of the same name.
@MainActor
final class TransferController: ObservableObject {
    @Published var conflict: ConflictRequest?

    private var waiting: [(ConflictRequest, CheckedContinuation<(ConflictDecision, Bool), Never>)] = []

    func resolve(_ decision: ConflictDecision, applyToAll: Bool) {
        guard !waiting.isEmpty else { conflict = nil; return }
        let (_, continuation) = waiting.removeFirst()
        conflict = waiting.first?.0
        continuation.resume(returning: (decision, applyToAll))
    }

    private func ask(source: URL, destination: URL) async -> (ConflictDecision, Bool) {
        await withCheckedContinuation { continuation in
            let request = ConflictRequest(source: source, destination: destination)
            waiting.append((request, continuation))
            if conflict == nil { conflict = request }
        }
    }

    /// Copies or moves `sources` to `destination`. With `rename` set, the single source is
    /// given that name - copy-and-rename, as typing a full path in the F5 box does.
    func run(kind: TransferKind, sources: [URL], destination: URL, rename: String? = nil,
             job: Job) async -> TransferOutcome {
        var outcome = TransferOutcome()
        var blanket: ConflictDecision?
        let fm = FileManager.default

        for source in sources {
            if job.cancelRequested { outcome.cancelled = true; break }
            job.started(source.lastPathComponent)

            var target = destination.appendingPathComponent(rename ?? source.lastPathComponent)

            // Copying a file into its own folder makes a numbered duplicate.
            if source.standardizedFileURL == target.standardizedFileURL {
                guard kind == .copy else { job.finished(of: sources.count); continue }
                target = Self.uniqueURL(for: target)
            } else if target.path.hasPrefix(source.path + "/") {
                outcome.errors.append("\(source.lastPathComponent): cannot go inside itself")
                job.finished(of: sources.count)
                continue
            } else if fm.fileExists(atPath: target.path) {
                let decision: ConflictDecision
                if let blanket {
                    decision = blanket
                } else {
                    let (choice, all) = await ask(source: source, destination: target)
                    if all { blanket = choice }
                    decision = choice
                }
                switch decision {
                case .cancel:
                    outcome.cancelled = true
                    job.cancelRequested = true
                    continue
                case .skip:
                    job.finished(of: sources.count)
                    continue
                case .keepBoth:
                    target = Self.uniqueURL(for: target)
                case .overwrite:
                    // Trash rather than delete, so replacing a file is recoverable.
                    do { try fm.trashItem(at: target, resultingItemURL: nil) } catch {
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
            job.finished(of: sources.count)
        }
        return outcome
    }

    /// To the Trash, or gone for good.
    func delete(_ urls: [URL], toTrash: Bool, job: Job) async -> [String] {
        var errors: [String] = []
        for url in urls {
            if job.cancelRequested { break }
            job.started(url.lastPathComponent)
            do {
                try await Task.detached(priority: .userInitiated) {
                    if toTrash { try FileManager().trashItem(at: url, resultingItemURL: nil) }
                    else { try FileManager().removeItem(at: url) }
                }.value
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            job.finished(of: urls.count)
        }
        return errors
    }

    /// Copying out of an archive extracts to a staging folder first, then hands the real
    /// files to the ordinary copy, so it gets the same conflict question and undo.
    func copyOut(paths: [String], from archive: URL, strippingComponents: Int, to destination: URL,
                 rename: String?, job: Job) async -> TransferOutcome {
        var outcome = TransferOutcome()
        guard !paths.isEmpty else { return outcome }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MACCommander-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        job.started(archive.lastPathComponent)
        do {
            try await Task.detached(priority: .userInitiated) {
                try ArchiveService.extractEntries(paths, from: archive, into: staging,
                                                  strippingComponents: strippingComponents)
            }.value
        } catch {
            outcome.errors.append("\(archive.lastPathComponent): \(error.localizedDescription)")
            return outcome
        }

        let staged = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard !staged.isEmpty else {
            outcome.errors.append("Nothing was read out of \(archive.lastPathComponent).")
            return outcome
        }
        return await run(kind: .copy, sources: staged, destination: destination,
                         rename: staged.count == 1 ? rename : nil, job: job)
    }

    /// "report.pdf" -> "report 2.pdf", "report 3.pdf", ...
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
