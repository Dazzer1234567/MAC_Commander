// Renders icons/logo.svg into a full .iconset, then leaves iconutil to pack it.
// AppKit loads SVG as a vector representation, so each size is drawn fresh
// rather than resampled from one bitmap.
//
//   swift Tools/make-icon.swift [svg] [iconset-dir]

import AppKit

let svgPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons/logo.svg"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icons/AppIcon.iconset"

guard let source = NSImage(contentsOf: URL(fileURLWithPath: svgPath)) else {
    FileHandle.standardError.write(Data("could not read \(svgPath)\n".utf8))
    exit(1)
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

// macOS icons leave breathing room around the artwork rather than bleeding to
// the edge of the tile.
let insetFraction: CGFloat = 0.08

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, pixels) in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        FileHandle.standardError.write(Data("could not allocate \(pixels)px bitmap\n".utf8))
        exit(1)
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let side = CGFloat(pixels)
    let margin = (side * insetFraction).rounded()
    let box = NSRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    source.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

print("wrote \(sizes.count) sizes to \(outDir)")
