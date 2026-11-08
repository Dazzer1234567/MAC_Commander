import AppKit
import SwiftUI

/// What the unpack dialog was closed with: the folder to unpack into, and how.
struct UnpackRequest: Sendable {
    let folder: String
    let options: UnpackOptions
}

/// Unpack files, after Total Commander's: where to, which files, and its boxes for path
/// names, overwriting, and a folder for each archive.
struct UnpackSheet: View {
    let prompt: String
    /// Where it is offered: the other pane's folder.
    let folder: String
    let onDone: (UnpackRequest?) -> Void

    init(prompt: String, folder: String, onDone: @escaping (UnpackRequest?) -> Void) {
        self.prompt = prompt
        self.folder = folder
        self.onDone = onDone
        let defaults = UserDefaults.standard
        _target = State(initialValue: folder.hasSuffix("/") ? folder : folder + "/")
        _mask = State(initialValue: defaults.string(forKey: Saved.mask) ?? "*.*")
        _keepPaths = State(initialValue: defaults.object(forKey: Saved.keepPaths) == nil || defaults.bool(forKey: Saved.keepPaths))
        _ownFolder = State(initialValue: defaults.bool(forKey: Saved.ownFolder))
    }

    @Environment(\.ui) private var ui
    @State private var target = ""
    @State private var mask = "*.*"
    @State private var keepPaths = true
    @State private var overwrite = false
    @State private var ownFolder = false
    @State private var error: String?
    @State private var focus = 0

    /// The dialog reopens with the boxes as they were left. Not Overwrite: that replaces
    /// files without asking, and has to be asked for each time.
    private enum Saved {
        static let mask = "unpack.mask"
        static let keepPaths = "unpack.keepPaths"
        static let ownFolder = "unpack.ownFolder"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(12)) {
            Text("Unpack files").font(ui.font(13, .semibold)).foregroundStyle(ui.text)
            Text(prompt).font(ui.font(12)).foregroundStyle(ui.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: ui.s(8)) {
                DazTextField(text: $target, font: ui.nsMono(12), textColor: ui.palette.text,
                             background: ui.palette.panel, selectAllOnAppear: true, focusTrigger: focus,
                             onSubmit: ok, onCancel: { onDone(nil) })
                    .frame(height: ui.s(24))
                Button("Browse…", action: browse)
                    .buttonStyle(DazButtonStyle())
                    .help("Choose the folder to unpack into")
            }

            // The boxes are Total Commander's, in its order and its words.
            HStack(spacing: ui.s(10)) {
                Text("Unpack specific files:").font(ui.font(12)).foregroundStyle(ui.dim)
                DazTextField(text: $mask, font: ui.nsMono(12), textColor: ui.palette.text,
                             background: ui.palette.panel, onSubmit: ok, onCancel: { onDone(nil) })
                    .frame(height: ui.s(24))
                    .help("*.txt;*.md takes out either. | leaves out: *.* | *.bak")
            }
            .padding(.top, ui.s(4))

            VStack(alignment: .leading, spacing: ui.s(9)) {
                box("Unpack path names if stored with files", $keepPaths)
                box("Overwrite existing files", $overwrite)
                box("Unpack each archive to a separate subdir (name of the archive)", $ownFolder)
            }
            .padding(.top, ui.s(4))

            // What the boxes as they stand will do. Room is kept for three lines, so the
            // sheet does not change height as they are ticked.
            Text(error ?? notes)
                .font(ui.font(11))
                .foregroundStyle(error == nil ? ui.dim : ui.marked)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: ui.s(46), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: ui.s(8)) {
                Spacer()
                Button("OK", action: ok)
                    .buttonStyle(DazButtonStyle()).frame(minWidth: ui.s(90))
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { onDone(nil) }
                    .buttonStyle(DazButtonStyle()).frame(minWidth: ui.s(90))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(ui.s(18))
        .frame(width: ui.s(680))
        .background(ui.window)
        .onChange(of: target) { error = nil }
    }

    private func box(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value)
            .toggleStyle(.checkbox)
            .font(ui.font(12))
            .foregroundStyle(ui.text)
    }

    private var notes: String {
        var lines: [String] = []
        if ownFolder { lines.append("Each archive goes into a folder of its own, named after it, in the folder given above.") }
        if !keepPaths {
            lines.append("Everything lands in the one folder; a second file of the same name is reported, not written over the first.")
        } else if !ZipUnpacker.Mask(mask).matchesEverything {
            lines.append("Only the files the mask picks come out, in their folders; empty folders stay behind.")
        }
        lines.append(overwrite ? "Files that are there already are replaced without asking."
                               : "Files that are there already are asked about once, before anything is written.")
        return lines.joined(separator: "\n")
    }

    private func browse() {
        let start = ZipUnpacker.resolve(target, folder: folder).folder ?? folder

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Unpack into"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: start, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = URL(fileURLWithPath: start)
        }
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        target = chosen.hasSuffix("/") ? chosen : chosen + "/"
    }

    private func ok() {
        let (path, why) = ZipUnpacker.resolve(target, folder: folder)
        guard let path else {
            error = why ?? "That is not somewhere files can be unpacked to."
            focus += 1
            return
        }
        // nothing typed means everything, as it does in Find files
        let trimmed = mask.trimmingCharacters(in: .whitespaces)
        let options = UnpackOptions(mask: trimmed.isEmpty ? "*.*" : trimmed, keepPaths: keepPaths,
                                    overwrite: overwrite, ownFolder: ownFolder)
        let defaults = UserDefaults.standard
        defaults.set(options.mask, forKey: Saved.mask)
        defaults.set(keepPaths, forKey: Saved.keepPaths)
        defaults.set(ownFolder, forKey: Saved.ownFolder)
        onDone(UnpackRequest(folder: path, options: options))
    }
}
