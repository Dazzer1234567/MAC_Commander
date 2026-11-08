import AppKit
import SwiftUI

/// F3: a quick look at a file as text or as hex, picked by sniffing the first few KB.
struct ViewerSheet: View {
    let path: String
    let onClose: () -> Void

    /// Only the head of a large file is loaded; this is a viewer, not an editor.
    nonisolated static let maxBytes = 8 * 1024 * 1024
    /// Hex runs to about five characters per byte, so it gets a shorter head than text to
    /// keep a big binary opening at once rather than after a long pause.
    nonisolated static let maxHexBytes = 2 * 1024 * 1024

    enum Mode { case text, hex }

    @Environment(\.ui) private var ui
    @State private var bytes: Data?
    @State private var fullLength: Int64 = 0
    @State private var failure: String?
    @State private var mode: Mode = .text
    @State private var shown = ""
    @State private var wrap = false
    @State private var rendering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ui.s(6)) {
                Button("Text") { show(.text) }
                    .buttonStyle(DazButtonStyle(toggled: mode == .text && bytes != nil))
                    .frame(minWidth: ui.s(70))
                Button("Hex") { show(.hex) }
                    .buttonStyle(DazButtonStyle(toggled: mode == .hex && bytes != nil))
                    .frame(minWidth: ui.s(70))
                Button("Wrap") { wrap.toggle() }
                    .buttonStyle(DazButtonStyle(toggled: wrap))
                    .frame(minWidth: ui.s(70))
                Button("Close (Esc)", action: onClose)
                    .buttonStyle(DazButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("View — \((path as NSString).lastPathComponent)")
                    .font(ui.font(12, .semibold)).foregroundStyle(ui.text)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(ui.s(6))

            ZStack {
                ViewerText(text: failure.map { "Can't read this file:\n\($0)" } ?? shown,
                           wrap: wrap, font: ui.nsMono(12), textColor: ui.palette.text,
                           background: ui.palette.panel, onCancel: onClose)
                    .overlay(Rectangle().strokeBorder(ui.border, lineWidth: 1))
                if (bytes == nil && failure == nil) || rendering {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, ui.s(6))

            HStack {
                Text(info)
                    .font(ui.font(11)).foregroundStyle(ui.dim)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ui.s(6)).padding(.vertical, ui.s(3))
            .background(ui.header)
            .padding(.top, ui.s(6))
        }
        .frame(width: ui.s(1000), height: ui.s(700))
        .background(ui.window)
        .task { await load() }
    }

    private var info: String {
        guard bytes != nil else { return path }
        let cap = mode == .hex ? Self.maxHexBytes : Self.maxBytes
        let truncated = fullLength > Int64(cap) ? "  (showing first \(Listing.formatBytes(Int64(cap))))" : ""
        return "\(path)  —  \(Listing.formatBytes(fullLength))  —  \(mode == .hex ? "hex" : "text")\(truncated)"
    }

    private func load() async {
        let path = self.path
        let result: Result<(Data, Int64), Error> = await Task.detached(priority: .userInitiated) {
            Result { try ViewerSheet.readHead(path) }
        }.value
        switch result {
        case .success(let (data, length)):
            fullLength = length
            bytes = data
            show(ViewerSheet.looksBinary(data) ? .hex : .text)
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    /// Lays the bytes out off the main thread: an 8 MB file is a lot of string to build.
    private func show(_ next: Mode) {
        guard let data = bytes else { return }
        mode = next
        rendering = true
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                next == .hex ? ViewerSheet.hexDump(data.prefix(ViewerSheet.maxHexBytes)) : ViewerSheet.decode(data)
            }.value
            // A later click wins over an earlier one still being laid out.
            if mode == next {
                shown = text
                rendering = false
            }
        }
    }

    nonisolated static func readHead(_ path: String) throws -> (Data, Int64) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let length = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        return (data, length)
    }

    nonisolated static func looksBinary(_ data: Data) -> Bool {
        // A NUL byte in the first few KB is the usual giveaway.
        data.prefix(8192).contains(0)
    }

    /// UTF-8, with anything that is not valid UTF-8 shown as a replacement mark rather
    /// than refusing the whole file.
    nonisolated static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    nonisolated static func hexDump(_ data: Data) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 16 * 78 + 80)

        func hex(_ value: Int, width: Int) {
            for shift in stride(from: (width - 1) * 4, through: 0, by: -4) {
                out.append(digits[(value >> shift) & 0xF])
            }
        }

        var offset = 0
        while offset < bytes.count {
            let count = min(16, bytes.count - offset)
            hex(offset, width: 8)
            out.append(contentsOf: [0x20, 0x20])
            for i in 0..<16 {
                if i < count { hex(Int(bytes[offset + i]), width: 2) } else { out.append(contentsOf: [0x20, 0x20]) }
                out.append(0x20)
                if i == 7 { out.append(0x20) }
            }
            out.append(0x20)
            for i in 0..<count {
                let b = bytes[offset + i]
                out.append(b >= 32 && b < 127 ? b : UInt8(ascii: "."))
            }
            out.append(0x0A)
            offset += 16
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// A read-only, scrollable text view. SwiftUI's Text would lay out megabytes at once;
/// NSTextView only lays out what is on screen.
private struct ViewerText: NSViewRepresentable {
    let text: String
    let wrap: Bool
    let font: NSFont
    let textColor: NSColor
    let background: NSColor
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = CancellingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        scroll.documentView = view

        context.coordinator.lastText = nil
        update(scroll, view: view, context: context)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CancellingTextView else { return }
        update(scroll, view: view, context: context)
    }

    private func update(_ scroll: NSScrollView, view: CancellingTextView, context: Context) {
        view.onCancel = onCancel
        view.backgroundColor = background
        scroll.backgroundColor = background
        view.textColor = textColor
        view.font = font

        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            view.string = text
            view.textColor = textColor
            view.font = font
            view.scroll(.zero)
        }

        if context.coordinator.lastWrap != wrap {
            context.coordinator.lastWrap = wrap
            guard let container = view.textContainer else { return }
            if wrap {
                view.isHorizontallyResizable = false
                container.widthTracksTextView = true
                container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
                view.frame.size.width = scroll.contentSize.width
            } else {
                view.isHorizontallyResizable = true
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastText: String?
        var lastWrap: Bool?
    }

    /// Escape closes the viewer even while the text has the keyboard.
    final class CancellingTextView: NSTextView {
        var onCancel: () -> Void = {}
        override func cancelOperation(_ sender: Any?) { onCancel() }
    }
}
