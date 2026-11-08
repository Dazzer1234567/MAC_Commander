import AppKit
import Foundation

/// Dark or light colours. Stored by name so the file stays readable, and an unknown
/// name falls back to dark rather than costing the user their workspaces.
enum AppTheme: String, Codable {
    case dark, light

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "dark"
        self = AppTheme(rawValue: raw.lowercased()) ?? .dark
    }
}

/// One button on the workspace toolbar, or a dropped item on the centre strip.
final class Shortcut: Codable, Identifiable, Equatable {
    let id: UUID
    /// Text shown on the button, when `showLabel` is set.
    var label: String
    /// A folder to jump to, or an app or document to open.
    var target: String
    /// Arguments, used only when the target is a program.
    var arguments: String?
    /// Which bar the button sits on: 0 is the main bar, 1 the first one below it.
    var row: Int
    /// False draws the icon alone. Applications default to this: their icon already
    /// identifies them, and a row of icons scans faster than a row of names.
    var showLabel: Bool
    /// `builtin:buttons/<name>` for the bundled library, or a file to take the icon from.
    /// Nil means the target's own icon.
    var iconSource: String?
    /// How large the icon is drawn. Nil means the usual size.
    var iconSize: Double?

    static let usualIconSize: Double = 30
    static let smallestIconSize: Double = 12

    init(label: String, target: String, arguments: String? = nil, row: Int = 0,
         showLabel: Bool = true, iconSource: String? = nil, iconSize: Double? = nil) {
        self.id = UUID()
        self.label = label
        self.target = target
        self.arguments = arguments
        self.row = row
        self.showLabel = showLabel
        self.iconSource = iconSource
        self.iconSize = iconSize
    }

    enum CodingKeys: String, CodingKey {
        case label, target, arguments, row, showLabel, iconSource, iconSize
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        target = (try? c.decode(String.self, forKey: .target)) ?? ""
        arguments = try? c.decode(String.self, forKey: .arguments)
        row = (try? c.decode(Int.self, forKey: .row)) ?? 0
        showLabel = (try? c.decode(Bool.self, forKey: .showLabel)) ?? true
        iconSource = try? c.decode(String.self, forKey: .iconSource)
        iconSize = try? c.decode(Double.self, forKey: .iconSize)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(arguments, forKey: .arguments)
        try c.encode(row, forKey: .row)
        try c.encode(showLabel, forKey: .showLabel)
        try c.encodeIfPresent(iconSource, forKey: .iconSource)
        try c.encodeIfPresent(iconSize, forKey: .iconSize)
    }

    static func == (a: Shortcut, b: Shortcut) -> Bool { a === b }

    /// The size to draw at, kept to what the button it sits on has room for.
    func iconSize(within largest: Double) -> Double {
        min(max(iconSize ?? Shortcut.usualIconSize, Shortcut.smallestIconSize),
            max(Shortcut.smallestIconSize, largest))
    }

    /// Apps stand alone on a button: their icon already identifies them.
    static func isApplication(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "app"
    }

    /// Things that can be handed files. Dropping a file onto a shortcut to a document should
    /// do nothing rather than try to pass one document to another.
    static func acceptsFiles(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "app" { return true }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            return FileManager.default.isExecutableFile(atPath: path)
        }
        return false
    }
}

/// A remembered pair of folders, one per pane, restored by a single button. Kept per
/// workspace, on the same reasoning as the shortcuts.
final class PaneLayout: Codable, Identifiable, Equatable {
    let id = UUID()
    var name: String
    var leftPath: String
    var rightPath: String
    /// Button width in points.
    var width: Double

    static let defaultWidth: Double = 170
    static let minWidth: Double = 70
    static let maxWidth: Double = 600

    init(name: String, leftPath: String, rightPath: String, width: Double = PaneLayout.defaultWidth) {
        self.name = name
        self.leftPath = leftPath
        self.rightPath = rightPath
        self.width = width
    }

    enum CodingKeys: String, CodingKey { case name, leftPath, rightPath, width }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        leftPath = (try? c.decode(String.self, forKey: .leftPath)) ?? ""
        rightPath = (try? c.decode(String.self, forKey: .rightPath)) ?? ""
        width = (try? c.decode(Double.self, forKey: .width)) ?? PaneLayout.defaultWidth
    }

    static func == (a: PaneLayout, b: PaneLayout) -> Bool { a === b }

    /// Just the two folder names, for the second line of the button.
    var summary: String { "\(Paths.leaf(leftPath))  |  \(Paths.leaf(rightPath))" }
}

/// A named set of shortcut buttons. Only one is shown at a time.
final class Workspace: Codable, Identifiable, Equatable {
    let id = UUID()
    var name: String
    var buttons: [Shortcut]
    /// How many bars of shortcuts the toolbar shows, the main one included.
    var shortcutRows: Int
    /// Saved pane pairs, shown on the bar below the shortcuts.
    var layouts: [PaneLayout]

    init(name: String) {
        self.name = name
        buttons = []
        shortcutRows = 1
        layouts = []
    }

    enum CodingKeys: String, CodingKey { case name, buttons, shortcutRows, layouts }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "General"
        buttons = (try? c.decode([Shortcut].self, forKey: .buttons)) ?? []
        shortcutRows = (try? c.decode(Int.self, forKey: .shortcutRows)) ?? 1
        layouts = (try? c.decode([PaneLayout].self, forKey: .layouts)) ?? []
    }

    static func == (a: Workspace, b: Workspace) -> Bool { a === b }

    /// The shortcuts on one row, in the order they are drawn.
    func buttons(onRow row: Int) -> [Shortcut] {
        let last = max(0, shortcutRows - 1)
        return buttons.filter { min(max($0.row, 0), last) == row }
    }
}

/// One button on the centre strip: either one of the app's own commands or something
/// dropped onto the strip, so both kinds sit in a single order.
final class CenterItem: Codable, Identifiable, Equatable {
    let id = UUID()
    /// A built-in command, or empty when this is something that was dropped here.
    var command: String
    /// What the button points at, or for a built-in just how it is drawn.
    var shortcut: Shortcut?

    var isBuiltIn: Bool { !command.isEmpty }

    /// The shortcut, created on demand so an older settings file gains one.
    var look: Shortcut {
        if let shortcut { return shortcut }
        let made = Shortcut(label: CenterItem.defaultLabels[command] ?? "", target: "", showLabel: false)
        shortcut = made
        return made
    }

    init(command: String) { self.command = command }
    init(shortcut: Shortcut) { command = ""; self.shortcut = shortcut }

    enum CodingKeys: String, CodingKey { case command, shortcut }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = (try? c.decode(String.self, forKey: .command)) ?? ""
        shortcut = try? c.decode(Shortcut.self, forKey: .shortcut)
    }

    static func == (a: CenterItem, b: CenterItem) -> Bool { a === b }

    static let volume = "volume"
    static let match = "match"
    static let quickFolder = "quickFolder"
    static let scratchpad = "scratchpad"
    static let copyName = "copyName"
    static let copyPath = "copyPath"
    static let search = "search"

    static let builtIns = [volume, match, quickFolder, scratchpad, copyName, copyPath, search]

    static let defaultLabels: [String: String] = [
        volume: "Volumes",
        match: "Match panes",
        quickFolder: "Quick folder",
        scratchpad: "Scratchpad",
        copyName: "Copy name",
        copyPath: "Copy full path",
        search: "Find files",
    ]
}

/// Everything remembered between runs, in one JSON file:
/// `~/Library/Application Support/MACCommander/settings.json`.
final class AppSettings: Codable {
    var leftPath: String = Paths.home
    var rightPath: String = Paths.downloads
    var windowWidth: Double = 1280
    var windowHeight: Double = 760
    var windowLeft: Double?
    var windowTop: Double?
    /// Left pane width as a fraction of the pane area.
    var splitRatio: Double = 0.5
    var showHidden = false
    var uiScale: Double = 1.0
    var theme: AppTheme = .dark
    /// The app F4 opens files in.
    var editor: String = "TextEdit"
    var workspaces: [Workspace] = []
    var activeWorkspace: String = ""
    /// Folder the centre strip's arrow jumps to. Shared across workspaces.
    var quickFolder: String = Paths.downloads
    /// Where the V button goes.
    var volumePath: String = "/Volumes"
    var centerBar: [CenterItem] = []
    /// Built-ins that have been put on the strip at least once, so one the user removed
    /// does not come straight back on the next start.
    var seededCenterCommands: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case leftPath, rightPath, windowWidth, windowHeight, windowLeft, windowTop, splitRatio
        case showHidden, uiScale, theme, editor, workspaces, activeWorkspace, quickFolder
        case volumePath, centerBar, seededCenterCommands
    }

    /// Every field is optional on the way in: one missing or mistyped value must not cost
    /// the user everything else in the file.
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        leftPath = get(.leftPath, Paths.home)
        rightPath = get(.rightPath, Paths.downloads)
        windowWidth = get(.windowWidth, 1280)
        windowHeight = get(.windowHeight, 760)
        windowLeft = try? c.decode(Double.self, forKey: .windowLeft)
        windowTop = try? c.decode(Double.self, forKey: .windowTop)
        splitRatio = get(.splitRatio, 0.5)
        showHidden = get(.showHidden, false)
        uiScale = get(.uiScale, 1.0)
        theme = get(.theme, AppTheme.dark)
        editor = get(.editor, "TextEdit")
        workspaces = get(.workspaces, [])
        activeWorkspace = get(.activeWorkspace, "")
        quickFolder = get(.quickFolder, Paths.downloads)
        volumePath = get(.volumePath, "/Volumes")
        centerBar = get(.centerBar, [])
        seededCenterCommands = get(.seededCenterCommands, [])
    }

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MACCommander").appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(AppSettings.self, from: data).withDefaults()
            } catch {
                // Corrupt settings must never block startup, but the next save would
                // overwrite the file, so keep a copy to recover from.
                try? FileManager.default.removeItem(at: url.appendingPathExtension("bad"))
                try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("bad"))
            }
        }
        let fresh = AppSettings()
        fresh.migrateOldLinks()
        return fresh.withDefaults()
    }

    /// The earlier version kept a bar of pinned folders in UserDefaults. They become
    /// shortcuts in the first workspace, so nothing pinned is lost.
    private func migrateOldLinks() {
        struct OldLink: Decodable { var name: String; var path: String }
        guard let data = UserDefaults.standard.data(forKey: "links.v1"),
              let links = try? JSONDecoder().decode([OldLink].self, from: data),
              !links.isEmpty else { return }
        let workspace = Workspace(name: "General")
        workspace.buttons = links.map { Shortcut(label: $0.name, target: $0.path) }
        workspaces = [workspace]
    }

    /// Fills in anything an older or hand-edited file may be missing.
    private func withDefaults() -> AppSettings {
        if workspaces.isEmpty { workspaces.append(Workspace(name: "General")) }
        if !workspaces.contains(where: { $0.name == activeWorkspace }) {
            activeWorkspace = workspaces[0].name
        }
        for command in CenterItem.builtIns where !seededCenterCommands.contains(command) {
            seededCenterCommands.append(command)
            if !centerBar.contains(where: { $0.command == command }) {
                centerBar.append(CenterItem(command: command))
            }
        }
        if quickFolder.trimmingCharacters(in: .whitespaces).isEmpty { quickFolder = Paths.downloads }
        if volumePath.trimmingCharacters(in: .whitespaces).isEmpty { volumePath = "/Volumes" }
        uiScale = UIScale.nearest(uiScale)
        return self
    }

    func save() {
        let url = AppSettings.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            // saving settings is best effort
        }
    }
}

/// Path helpers shared by the models and the views.
enum Paths {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var downloads: String { home + "/Downloads" }

    /// The last component, or the path itself for a root.
    static func leaf(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        let name = (trimmed as NSString).lastPathComponent
        if trimmed == "/" { return "Macintosh HD" }
        return name.isEmpty ? trimmed : name
    }

    /// Whether two paths name the same folder, compared as text.
    static func same(_ a: String, _ b: String) -> Bool {
        func tidy(_ p: String) -> String {
            var t = p.trimmingCharacters(in: .whitespaces)
            while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
            return t.lowercased()
        }
        return tidy(a) == tidy(b)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Folders keep their name; files drop the extension, which reads better on a button.
    static func shortcutLabel(for path: String) -> String {
        if isDirectory(path) && !path.lowercased().hasSuffix(".app") { return leaf(path) }
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// Expands `~` and makes a path absolute against a base folder.
    static func resolve(_ typed: String, relativeTo base: String) -> String {
        var path = typed.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (base as NSString).appendingPathComponent(path) }
        return (path as NSString).standardizingPath
    }
}
