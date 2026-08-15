import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// Folders pinned to the top bar with the Link button. Separate from
/// `BookmarkStore` so the bar starts empty and only ever holds what you put
/// there, rather than the default Home/Desktop/Documents set.
@MainActor
final class LinkStore: ObservableObject {
    @Published var items: [Bookmark] = [] {
        didSet { save() }
    }

    private let storageKey = "links.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = decoded
        }
    }

    /// Returns false when the folder is already linked, so the caller can say so.
    @discardableResult
    func add(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !items.contains(where: { $0.path == path }) else { return false }
        let name = standardized.lastPathComponent
        items.append(Bookmark(name: name.isEmpty || name == "/" ? "Macintosh HD" : name, path: path))
        return true
    }

    func remove(_ link: Bookmark) {
        items.removeAll { $0.id == link.id }
    }

    func removeAll() {
        items.removeAll()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published var items: [Bookmark] = [] {
        didSet { save() }
    }

    private let storageKey = "bookmarks.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = decoded
        } else {
            items = BookmarkStore.starterSet
        }
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !items.contains(where: { $0.path == path }) else { return }
        items.append(Bookmark(name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent, path: path))
    }

    func remove(_ bookmark: Bookmark) {
        items.removeAll { $0.id == bookmark.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func resetToDefaults() {
        items = BookmarkStore.starterSet
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static var starterSet: [Bookmark] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Bookmark(name: "Home", path: home.path),
            Bookmark(name: "Desktop", path: home.appendingPathComponent("Desktop").path),
            Bookmark(name: "Documents", path: home.appendingPathComponent("Documents").path),
            Bookmark(name: "Downloads", path: home.appendingPathComponent("Downloads").path),
            Bookmark(name: "Applications", path: "/Applications"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
