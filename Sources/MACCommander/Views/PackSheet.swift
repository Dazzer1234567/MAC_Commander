import AppKit
import SwiftUI

/// What the pack dialog was closed with: the archive to make, and how.
struct PackRequest: Sendable {
    let archive: String
    let options: PackOptions
}

/// Pack files, after Total Commander's: where the archive goes, and its boxes for path
/// names, subdirectories, moving and separate archives. Zip is the only packer there is, so
/// its list of packers is left out, and with it the boxes that belong to the others.
struct PackSheet: View {
    let items: [FileItem]
    /// Where the archive is offered: the other pane's folder.
    let folder: String
    /// What it is offered as, without the extension.
    let name: String
    let onDone: (PackRequest?) -> Void

    init(items: [FileItem], folder: String, name: String, onDone: @escaping (PackRequest?) -> Void) {
        self.items = items
        self.folder = folder
        self.name = name
        self.onDone = onDone
        let defaults = UserDefaults.standard
        _archive = State(initialValue: (folder as NSString).appendingPathComponent(name + ".zip"))
        _keepPaths = State(initialValue: defaults.object(forKey: Saved.keepPaths) == nil || defaults.bool(forKey: Saved.keepPaths))
        _recurse = State(initialValue: defaults.object(forKey: Saved.recurse) == nil || defaults.bool(forKey: Saved.recurse))
        _level = State(initialValue: defaults.string(forKey: Saved.level).flatMap(PackLevel.init(rawValue:)) ?? .normal)
    }

    @Environment(\.ui) private var ui
    @State private var archive = ""
    @State private var keepPaths = true
    @State private var recurse = true
    @State private var move = false
    @State private var separate = false
    @State private var level: PackLevel = .normal
    @State private var error: String?
    @State private var focus = 0

    /// The dialog reopens with the boxes as they were left. Not Move or Separate: a move
    /// takes the originals away, and has to be asked for each time.
    private enum Saved {
        static let keepPaths = "pack.keepPaths"
        static let recurse = "pack.recurse"
        static let level = "pack.level"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s(12)) {
            Text("Pack files").font(ui.font(13, .semibold)).foregroundStyle(ui.text)
            Text(items.count == 1 ? "Pack \"\(items[0].name)\" to the zip file:"
                                  : "Pack \(items.count) selected items to the zip file:")
                .font(ui.font(12)).foregroundStyle(ui.text)

            HStack(spacing: ui.s(8)) {
                DazTextField(text: $archive, font: ui.nsMono(12), textColor: ui.palette.text,
                             background: ui.palette.panel, focusOnAppear: true, focusTrigger: focus,
                             onSubmit: ok, onCancel: { onDone(nil) })
                    .frame(height: ui.s(24))
                Button("Browse…", action: browse)
                    .buttonStyle(DazButtonStyle())
                    .help("Choose the folder the zip file goes in")
            }

            // The boxes are Total Commander's, in its order and its words.
            HStack(alignment: .top, spacing: ui.s(24)) {
                VStack(alignment: .leading, spacing: ui.s(9)) {
                    box("Also pack path names (only recursed)", $keepPaths).disabled(!recurse)
                    box("Recursively pack subdirectories", $recurse)
                    box("Move to archive", $move)
                    box("Create separate archives, one per selected file/dir", $separate)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: ui.s(4)) {
                    Text("Compression").font(ui.font(12)).foregroundStyle(ui.dim)
                    Picker("", selection: $level) {
                        ForEach(PackLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: ui.s(170))
                }
            }
            .padding(.top, ui.s(6))

            // What the boxes as they stand will do, a line to each. Room is kept for the
            // most there can be, three, so the sheet does not change height as they are ticked.
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
        .onAppear(perform: selectName)
        .onChange(of: archive) { error = nil }
    }

    private func box(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value)
            .toggleStyle(.checkbox)
            .font(ui.font(12))
            .foregroundStyle(ui.text)
    }

    private var options: PackOptions {
        PackOptions(keepPaths: keepPaths, recurse: recurse, move: move, separate: separate, level: level)
    }

    private var notes: String {
        var lines: [String] = []
        // Kept to a line: a path spelled out here would push the notes after it out of sight.
        if separate { lines.append("Each file and folder gets a zip file of its own, named after it, in the folder given above.") }
        if !recurse { lines.append("Folders are left out: only the files picked are packed.") }
        else if !keepPaths { lines.append("Files from inside folders all go in at the top of the zip file, without their folders.") }
        if move { lines.append("Once packed, the originals go to the Trash.") }
        return lines.joined(separator: "\n")
    }

    private func selectName() {
        // The name alone, which is the part most often changed. The field takes the
        // keyboard a moment after it appears, and the selection is made after that.
        let start = (archive as NSString).length - (name as NSString).length - 4
        let length = (name as NSString).length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, start >= 0 else { return }
            editor.setSelectedRange(NSRange(location: start, length: length))
            editor.scrollRangeToVisible(NSRange(location: start, length: length))
        }
    }

    private func browse() {
        let typed = ZipPacker.resolve(archive, folder: folder, name: name).archive
        let start = typed.map { ($0 as NSString).deletingLastPathComponent } ?? folder

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Put the zip file in"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: start, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = URL(fileURLWithPath: start)
        }
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }

        // the folder changes; the name that was typed stays
        archive = (chosen as NSString).appendingPathComponent(typed.map { ($0 as NSString).lastPathComponent } ?? name + ".zip")
    }

    private func ok() {
        let (path, why) = ZipPacker.resolve(archive, folder: folder, name: name)
        guard let path else {
            error = why ?? "That is not somewhere a zip file can go."
            focus += 1
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(keepPaths, forKey: Saved.keepPaths)
        defaults.set(recurse, forKey: Saved.recurse)
        defaults.set(level.rawValue, forKey: Saved.level)
        onDone(PackRequest(archive: path, options: options))
    }
}
