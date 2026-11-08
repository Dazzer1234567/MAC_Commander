import AppKit
import Foundation

/// One icon from the library bundled with the app.
struct BuiltInIcon: Identifiable, Hashable {
    /// Path under the buttons folder, e.g. `Alphabet ICO set/A-001.ico`.
    let relativePath: String
    /// The file name without its extension.
    let name: String
    /// The subfolder it sits in, or empty for the top of the folder.
    let group: String

    var id: String { relativePath }

    /// What gets written to settings.json.
    var reference: String { IconLibrary.libraryPrefix + relativePath }
}

/// The icons shortcuts are drawn with: the library under `Resources/buttons`, any icon or
/// image file on disk, or the target's own icon.
///
/// A shortcut refers to a library icon by a `builtin:buttons/...` reference rather than a
/// path, so the choice survives the app being moved. `.ico` and `.svg` are both read by
/// NSImage itself; what this adds on top is DAZ Commander's three rules for SVG:
///
/// - An icon drawn only in black, or only in white, is a glyph and is drawn in the ink -
///   the theme's text colour - so black does not vanish on the dark theme. It follows the
///   theme when it changes.
/// - An icon with two or more colours, or any gradient, keeps them, except `currentColor`,
///   which always means the ink.
/// - The drawing is fitted to a square, not its canvas. Icon sets disagree on how much empty
///   canvas to leave, and side by side on a bar they would come out at different sizes.
enum IconLibrary {
    static let prefix = "builtin:"
    static let libraryPrefix = "builtin:buttons/"

    // MARK: - The ink

    /// The colour glyphs are drawn in. The dark theme's text, until the theme says.
    private static var ink = NSColor(srgbRed: 0xD6 / 255.0, green: 0xD8 / 255.0, blue: 0xDC / 255.0, alpha: 1)
    private static var inkHex = "#D6D8DC"

    static func setInk(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        ink = rgb
        // The cache is keyed on this, so a change of theme draws the glyphs afresh.
        inkHex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                        Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    // MARK: - The bundled library

    /// The buttons folder: inside the app bundle, or the source tree's when run straight
    /// from `.build`.
    static let folder: URL? = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("buttons"), isDirectory(bundled) {
            return bundled
        }
        // .../Sources/MACCommander/Models/IconLibrary.swift -> .../Resources/buttons
        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { source.deleteLastPathComponent() }
        source = source.appendingPathComponent("Resources").appendingPathComponent("buttons")
        return isDirectory(source) ? source : nil
    }()

    /// Every bundled icon, grouped by subfolder and sorted by name. Only `.ico` and `.svg`
    /// are picked up; anything else in the folder is left alone.
    static let all: [BuiltInIcon] = {
        guard let folder, let paths = try? FileManager.default.subpathsOfDirectory(atPath: folder.path) else { return [] }
        return paths.compactMap { path -> BuiltInIcon? in
            let ext = (path as NSString).pathExtension.lowercased()
            guard ext == "ico" || ext == "svg" else { return nil }
            let group = (path as NSString).deletingLastPathComponent
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return BuiltInIcon(relativePath: path, name: name, group: group)
        }
        .sorted {
            let byGroup = $0.group.localizedCaseInsensitiveCompare($1.group)
            if byGroup != .orderedSame { return byGroup == .orderedAscending }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }()

    /// Lower-cased relative path to the icon, so a reference whose case has drifted - or
    /// one DAZ Commander wrote, lower-cased and URL-escaped - still finds its file.
    private static let byLowercasedPath: [String: BuiltInIcon] = {
        var map: [String: BuiltInIcon] = [:]
        for icon in all { map[icon.relativePath.lowercased()] = icon }
        return map
    }()

    static func isBuiltIn(_ source: String?) -> Bool { source?.hasPrefix(prefix) ?? false }

    /// The library icon a `builtin:` reference names, if it is still in the folder.
    static func builtIn(_ reference: String) -> BuiltInIcon? {
        guard reference.hasPrefix(libraryPrefix) else { return nil }
        let relative = String(reference.dropFirst(libraryPrefix.count))
        if let found = byLowercasedPath[relative.lowercased()] { return found }
        if let unescaped = relative.removingPercentEncoding { return byLowercasedPath[unescaped.lowercased()] }
        return nil
    }

    // MARK: - Looking icons up

    /// What a cache slot holds, so a source that failed is not tried again on every redraw.
    private enum Slot { case found(NSImage), missing }
    private static var cache: [String: Slot] = [:]

    /// The icon a shortcut shows: its chosen one, else its target's own, else nil.
    static func image(for shortcut: Shortcut) -> NSImage? {
        if let source = shortcut.iconSource, !source.isEmpty, let chosen = image(source: source) {
            return chosen
        }
        // a chosen icon whose file has gone falls through to the target's own
        return targetIcon(shortcut.target)
    }

    /// A chosen icon on its own: a `builtin:` reference or a file on disk. Nil when nothing
    /// can be read from it.
    static func image(source: String) -> NSImage? {
        if isBuiltIn(source) {
            guard let icon = builtIn(source), let url = folder?.appendingPathComponent(icon.relativePath) else { return nil }
            return image(at: url, stamp: "")
        }
        let path = (source as NSString).expandingTildeInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        // Read again only when the file has changed since.
        let written = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return image(at: URL(fileURLWithPath: path), stamp: "\(written)")
    }

    static func image(for icon: BuiltInIcon) -> NSImage? {
        image(source: icon.reference)
    }

    private static func image(at url: URL, stamp: String) -> NSImage? {
        let ext = url.pathExtension.lowercased()
        let isSVG = ext == "svg"
        // An SVG's look depends on the ink; nothing else's does.
        let key = "\(url.path)|\(stamp)" + (isSVG ? "|\(inkHex)" : "")
        if let slot = cache[key] {
            if case .found(let image) = slot { return image }
            return nil
        }
        let loaded: NSImage?
        if isSVG {
            loaded = (try? Data(contentsOf: url)).flatMap(svg)
        } else if ext == "app" || isDirectory(url) {
            // An app lends its own icon, as a folder does.
            loaded = NSWorkspace.shared.icon(forFile: url.path)
        } else if ext == "ico" {
            loaded = NSImage(contentsOf: url).map(nearestFrame)
        } else {
            // .icns, .png, .jpg, .pdf, .tiff... anything NSImage can read
            loaded = NSImage(contentsOf: url)
        }
        cache[key] = loaded.map(Slot.found) ?? .missing
        return loaded
    }

    /// The target's own icon. Nil when the target is not there, so the bar shows its text.
    private static func targetIcon(_ target: String) -> NSImage? {
        let path = (target as NSString).expandingTildeInPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let key = "target|\(path)"
        if case .found(let image)? = cache[key] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[key] = .found(image)
        return image
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - .ico frames

    /// An .ico holds several sizes. The one nearest the size being drawn is used, so neither
    /// a 16px nor a 256px frame is stretched into place. Ties go to the larger frame, which
    /// shrinks better than the smaller one grows.
    private static func nearestFrame(_ loaded: NSImage) -> NSImage {
        let frames = loaded.representations.compactMap { $0 as? NSBitmapImageRep }
        guard frames.count > 1 else { return loaded }
        let side = CGFloat(frames.map(\.pixelsWide).max() ?? 32)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let wanted = rect.width * deviceScale()
            guard let frame = frame(nearest: wanted, in: frames) else { return false }
            return frame.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                              hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        }
    }

    static func frame(nearest pixels: CGFloat, in frames: [NSBitmapImageRep]) -> NSBitmapImageRep? {
        frames.min { a, b in
            let da = abs(CGFloat(a.pixelsWide) - pixels), db = abs(CGFloat(b.pixelsWide) - pixels)
            return da != db ? da < db : a.pixelsWide > b.pixelsWide
        }
    }

    /// Device pixels per unit in the context being drawn into. The handler is handed the
    /// image's own bounds with the shrinking or Retina doubling left in the transform, so
    /// this is what turns the rectangle into the pixels it really covers.
    private static func deviceScale() -> CGFloat {
        guard let context = NSGraphicsContext.current?.cgContext else { return 1 }
        let t = context.userSpaceToDeviceSpaceTransform
        let scale = (t.a * t.a + t.c * t.c).squareRoot()
        return scale > 0 ? scale : 1
    }

    // MARK: - SVG

    /// Space left around the artwork, as a share of its longer side.
    private static let margin: CGFloat = 0.04
    /// Pixels on a side of the drawn square: room for the largest button at 200% on Retina.
    private static let svgSide = 256

    /// Applies the three rules: glyphs in the ink, `currentColor` as the ink, and the
    /// drawing fitted to a centred square. Nil when there is nothing to draw.
    private static func svg(_ data: Data) -> NSImage? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }

        // Whether it is a glyph is decided on its own colours: what it paints in
        // currentColor is the ink whatever happens, so it is left out of the count.
        guard let probe = NSImage(data: Data(replacingCurrentColor(in: text, with: "none").utf8)),
              let shown = NSImage(data: Data(replacingCurrentColor(in: text, with: inkHex).utf8)),
              shown.size.width > 0, shown.size.height > 0 else { return nil }
        let hasGradient = text.range(of: #"<\s*(\w+:)?(linear|radial)Gradient"#, options: [.regularExpression, .caseInsensitive]) != nil
        let isGlyph = !hasGradient && isOneColour(rasterize(probe, longest: 96))

        // Find where the drawing actually is, then draw it again framed by a square around that.
        let scan = rasterize(shown, longest: 512)
        guard let found = opaqueBounds(scan) else { return nil }
        let canvas = shown.size
        let toCanvas = canvas.width / CGFloat(scan.pixelsWide)
        // bitmap rows run top down; AppKit's y runs bottom up
        let art = CGRect(x: found.minX * toCanvas, y: canvas.height - found.maxY * toCanvas,
                         width: found.width * toCanvas, height: found.height * toCanvas)
        let square = max(art.width, art.height) * (1 + 2 * margin)
        let scale = CGFloat(svgSide) / square
        let origin = CGPoint(x: (square / 2 - art.midX) * scale, y: (square / 2 - art.midY) * scale)

        let out = bitmap(svgSide, svgSide)
        draw(into: out) {
            shown.draw(in: CGRect(origin: origin, size: CGSize(width: canvas.width * scale, height: canvas.height * scale)),
                       from: .zero, operation: .sourceOver, fraction: 1)
            if isGlyph {
                // keeps the drawing's own transparency, takes the ink's colour
                ink.setFill()
                CGRect(x: 0, y: 0, width: svgSide, height: svgSide).fill(using: .sourceIn)
            }
        }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        out.size = image.size
        image.addRepresentation(out)
        return image
    }

    /// `currentColor` swapped for a colour of our own, wherever it appears.
    private static func replacingCurrentColor(in text: String, with colour: String) -> String {
        text.replacingOccurrences(of: "currentColor", with: colour, options: .caseInsensitive)
    }

    /// Black or white, near enough: what a one-colour icon is drawn in. A drawing of only
    /// one of them is a glyph; both together, or anything else, is a coloured picture.
    private static func isOneColour(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return false }
        var dark = 0, light = 0, other = 0
        for i in 0..<(rep.pixelsWide * rep.pixelsHigh) {
            let p = data + i * 4
            let a = Int(p[3])
            // faint edge pixels carry too little colour to judge by
            guard a >= 96 else { continue }
            // the bitmap is premultiplied
            let r = Int(p[0]) * 255 / a, g = Int(p[1]) * 255 / a, b = Int(p[2]) * 255 / a
            let most = max(r, g, b), least = min(r, g, b)
            if most - least <= 24 && most <= 80 { dark += 1 }
            else if most - least <= 24 && least >= 232 { light += 1 }
            else { other += 1 }
        }
        let total = dark + light + other
        // An icon drawn wholly in currentColor has nothing left: that is a glyph too.
        guard total > 0 else { return true }
        // a sliver of blended pixels where shapes meet is not a second colour
        let sliver = max(1, total / 200)
        return other <= sliver && min(dark, light) <= sliver
    }

    /// The box around everything that is not transparent, in bitmap pixels from the top left.
    private static func opaqueBounds(_ rep: NSBitmapImageRep) -> CGRect? {
        guard let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh, row = rep.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * row + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The image drawn whole into a bitmap whose longer side is `longest` pixels.
    private static func rasterize(_ image: NSImage, longest: Int) -> NSBitmapImageRep {
        let size = image.size
        let scale = CGFloat(longest) / max(size.width, size.height)
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        let rep = bitmap(w, h)
        draw(into: rep) {
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        }
        return rep
    }

    private static func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: w * 4, bitsPerPixel: 32)!
    }

    private static func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        body()
        NSGraphicsContext.current?.flushGraphics()
    }
}
