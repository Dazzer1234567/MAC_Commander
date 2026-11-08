import Combine
import Foundation

/// Packing into a zip file and unpacking archives: ⌥F5 and ⌥F9, Total Commander's keys.
extension AppState {
    /// Packs the marked entries, or the one under the cursor, into a zip file. It is
    /// offered in the other pane's folder, under the name of the one thing picked or of the
    /// folder the several are in.
    func doPack() {
        let items = active.actionItems
        guard !items.isEmpty else { return }

        if active.inArchive {
            warn("Packing is not possible from inside an archive.\n\n"
                 + "What is in one is not on disk to be packed. Copy it out first, with F5.")
            return
        }
        if active.inShareList {
            warn("Packing is not possible in a computer's list of shared folders.\n\nOpen one of the shared folders first.")
            return
        }

        let sources = items.map(\.path)
        // The other pane may be inside an archive, where nothing can be put. The folder its
        // archive is in is the nearest place that can take one, and is only a suggestion.
        let folder = other.realFolder
        let name = ZipPacker.suggest(sources, folder: active.realFolder)
        let source = active, target = other

        Task {
            guard let request = await present({ (done: @escaping (PackRequest?) -> Void) in
                PackSheet(items: items, folder: folder, name: name, onDone: done)
            }) else { return }

            let plans = await Task.detached(priority: .userInitiated) {
                ZipPacker.plan(sources, archive: request.archive, options: request.options)
            }.value

            if plans.allSatisfy(\.isEmpty) {
                let why = plans.flatMap(\.refused).map { "\($0.name): \($0.why)" }
                warn(why.isEmpty
                     ? "There is nothing to pack. Folders are left out unless their subdirectories are packed too."
                     : "There is nothing to pack:\n\n" + listed(why))
                return
            }

            let clashes = plans.filter { !$0.isEmpty && $0.clashes }.map(\.archive)
            if let first = clashes.first {
                let what = clashes.count == 1
                    ? "\"\(Paths.leaf(first))\" is already there. Overwrite replaces it"
                    : "\(clashes.count) of these zip files are already there, \"\(Paths.leaf(first))\" among them. Overwrite replaces each"
                // Said in full: in Total Commander packing to an archive that is there adds
                // to it, and someone used to that would expect the same of this.
                guard await confirm("\(what) with a new zip file, holding only what is being packed now. "
                                    + "What is in it at the moment is not kept.",
                                    title: "Pack files", ok: "Overwrite") else { return }
            }

            // Started only now, after the question: its box would otherwise come up behind
            // the question while that was still being read.
            let mark = jobs.mark
            let job = jobs.start("Packing")
            let relay = ZipJobRelay(job)
            let level = request.options.level
            let outcome = await Task.detached(priority: .userInitiated) {
                ZipPacker.pack(plans, level: level, progress: relay)
            }.value
            jobs.finish(job)

            if !outcome.failures.isEmpty {
                warn("\(outcome.failures.count) could not be packed:\n\n" + listed(outcome.failures))
            }

            // Only what went in whole. A folder with one file left out of the archive stays
            // where it is, all of it.
            if request.options.move && !outcome.cancelled && !outcome.done.isEmpty {
                await takeAwayPacked(outcome.done)
            }

            // The pane that was packed from keeps its cursor. The one showing where the zip
            // file went puts its cursor on it: in a long folder it is otherwise invisible.
            if jobs.appeared(since: mark) {
                catchUpQuietly()
            } else {
                source.refresh()
                let landed = outcome.made.first
                let focus = landed.flatMap { Paths.same(target.currentPath, ($0 as NSString).deletingLastPathComponent) ? Paths.leaf($0) : nil }
                if target !== source { target.refresh(focus: focus) }
                source.focusRequest += 1
            }

            if let first = outcome.made.first {
                flash(outcome.made.count == 1
                      ? "Packed \(Listing.plural(outcome.packed, "file")) into \(Paths.leaf(first))"
                      : "Packed \(Listing.plural(outcome.packed, "file")) into \(outcome.made.count) zip files")
            }
        }
    }

    /// The second half of a move to an archive. To the Trash, where Total Commander deletes
    /// outright: the archive has been read back, but it is the only copy there is.
    private func takeAwayPacked(_ packed: [String]) async {
        let job = jobs.start("Deleting")
        let errors = await transfer.delete(packed.map { URL(fileURLWithPath: $0) }, toTrash: true, job: job)
        jobs.finish(job)
        if !errors.isEmpty {
            warn("The zip file was made, but the originals could not be taken away:\n" + listed(errors))
        }
    }

    /// Unpacks the marked archives, or the one under the cursor, into the other pane's
    /// folder. Inside an archive it unpacks what is marked there instead - F5 with the
    /// unpack dialog's choices.
    func doUnpack() {
        // Each archive, and what to take out of it: all of it, unless the pane is inside it.
        var work: [(place: ArchivePlace, names: [String]?)] = []
        let prompt: String

        if let (archive, inner) = active.archive {
            let items = active.actionItems
            guard !items.isEmpty else { return }
            work = [(ArchivePlace(archive: archive, inside: inner), items.map(\.name))]
            prompt = items.count == 1
                ? "Unpack \"\(items[0].name)\" from \(Paths.leaf(archive)) to:"
                : "Unpack \(items.count) selected items from \(Paths.leaf(archive)) to:"
        } else {
            let archives = active.actionItems.filter { !$0.isDirectory && !$0.isVirtual && !$0.isShare && ArchiveService.isArchive($0.url) }
            guard !archives.isEmpty else {
                warn("Pick an archive to unpack: mark it, or put the cursor on it.")
                return
            }
            work = archives.map { (ArchivePlace(archive: $0.path, inside: ""), nil) }
            prompt = archives.count == 1 ? "Unpack \"\(archives[0].name)\" to:" : "Unpack \(archives.count) archives to:"
        }

        // The other pane may be inside an archive, where nothing can be put. The folder its
        // archive is in is the nearest place that can take the files, and is only a suggestion.
        let folder = other.realFolder
        let jobsToDo = work

        Task {
            guard let request = await present({ (done: @escaping (UnpackRequest?) -> Void) in
                UnpackSheet(prompt: prompt, folder: folder, onDone: done)
            }) else { return }

            let (plans, planFailures) = await Task.detached(priority: .userInitiated) { () -> ([UnpackPlan], [String]) in
                var made: [UnpackPlan] = []
                var failures: [String] = []
                for (place, names) in jobsToDo {
                    // One archive that will not open must not cost the others.
                    do {
                        made.append(try ZipUnpacker.plan(place, names: try names ?? ZipUnpacker.everything(place),
                                                         target: request.folder, options: request.options))
                    } catch {
                        failures.append("\(Paths.leaf(place.archive)): \(ZipPacker.reason(error))")
                    }
                }
                return (made, failures)
            }.value
            var failures = planFailures

            let files = plans.reduce(0) { $0 + $1.plan.files.count }
            let folders = plans.reduce(0) { $0 + $1.plan.folders.count }

            if files == 0 && folders == 0 {
                failures += plans.flatMap(\.dropped)
                warn(failures.isEmpty
                     ? "There is nothing to unpack: no file matches \(request.options.mask)"
                     : "There is nothing to unpack:\n\n" + listed(failures))
                return
            }

            var overwrite = request.options.overwrite
            let clashes = plans.flatMap { $0.plan.clashes() }
            if !overwrite, let first = clashes.first {
                let what = clashes.count == 1
                    ? "\"\(Paths.leaf(first))\" is already there."
                    : "\(clashes.count) of these files are already there, \"\(Paths.leaf(first))\" among them."
                overwrite = await confirm("\(what)\n\nOverwrite replaces them with the ones from the archive. Cancel leaves "
                                          + "them as they are and unpacks only what is not there yet.",
                                          title: "Unpack files", ok: "Overwrite")
                // nothing left to do if every one of them was there already
                if !overwrite && clashes.count == files && folders == 0 { return }
            }

            // Started only now, after the question: its box would otherwise come up behind
            // the question while that was still being read.
            let mark = jobs.mark
            let job = jobs.start("Unpacking")
            let relay = ZipJobRelay(job)
            let replace = overwrite
            let outcome = await Task.detached(priority: .userInitiated) {
                ZipUnpacker.unpack(plans, overwrite: replace, progress: relay)
            }.value
            jobs.finish(job)

            // Where the cursor goes: onto the first thing unpacked, in whichever pane shows
            // the folder it went into - the archive's own folder, where each has one.
            let first = plans.first { $0.plan.files.count + $0.plan.folders.count > 0 }
            let landed: (folder: String, name: String)? = first.map {
                request.options.ownFolder ? (request.folder, Paths.leaf($0.folder)) : (request.folder, firstName($0))
            }

            if jobs.appeared(since: mark) { catchUpQuietly() } else { refreshBoth(landed: landed) }

            failures += outcome.failures
            if !failures.isEmpty {
                warn("\(failures.count) could not be unpacked:\n\n" + listed(failures))
            }
            if outcome.copied > 0 {
                flash(outcome.skipped > 0
                      ? "Unpacked \(Listing.plural(outcome.copied, "file")), left \(outcome.skipped) that were there"
                      : "Unpacked \(Listing.plural(outcome.copied, "file"))")
            }
            if !jobs.appeared(since: mark) { active.focusRequest += 1 }
        }
    }

    /// The name, in the folder unpacked into, of the first thing that came out there.
    private func firstName(_ plan: UnpackPlan) -> String {
        guard let path = plan.plan.files.map(\.to).first ?? plan.plan.folders.first else { return "" }
        let rest = path.hasPrefix(plan.folder + "/") ? String(path.dropFirst(plan.folder.count + 1)) : Paths.leaf(path)
        return rest.split(separator: "/").first.map(String.init) ?? rest
    }
}

/// Hands a pack or unpack's progress to its box. The work runs off the main thread and the
/// box lives on it, so what is said is passed across, and the box's Stop is read from a
/// copy kept here.
final class ZipJobRelay: ZipProgress, @unchecked Sendable {
    private let lock = NSLock()
    private var stop = false
    private var watch: AnyCancellable?
    private weak var job: Job?

    @MainActor
    init(_ job: Job) {
        self.job = job
        watch = job.$cancelRequested.sink { [weak self] value in
            guard let self else { return }
            self.lock.lock()
            self.stop = value
            self.lock.unlock()
        }
    }

    var cancelRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stop
    }

    func started(_ name: String) {
        DispatchQueue.main.async { [weak job] in
            MainActor.assumeIsolated { job?.started(name) }
        }
    }

    func finished(of total: Int) {
        DispatchQueue.main.async { [weak job] in
            MainActor.assumeIsolated { job?.finished(of: total) }
        }
    }
}
