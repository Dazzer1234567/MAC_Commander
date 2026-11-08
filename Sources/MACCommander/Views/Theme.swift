import AppKit
import SwiftUI

/// Every colour the app uses lives here and nowhere else. The two palettes have the same
/// keys, so either can be swapped in without anything else changing.
struct Palette {
    let window: NSColor
    let panel: NSColor
    let header: NSColor
    let border: NSColor
    let borderActive: NSColor
    let text: NSColor
    let textDim: NSColor
    let marked: NSColor
    let markedBg: NSColor
    /// Cursor row: bright while the pane has focus, muted while it does not.
    let cursor: NSColor
    let cursorInactive: NSColor
    let accent: NSColor
    let fnKey: NSColor
    let hover: NSColor
    let toggled: NSColor
    let good: NSColor

    static let dark = Palette(
        window: .hex(0x1E1F22), panel: .hex(0x141517), header: .hex(0x2B2D31),
        border: .hex(0x3A3D42), borderActive: .hex(0x4C8DFF),
        text: .hex(0xD6D8DC), textDim: .hex(0x8A8F98),
        marked: .hex(0xFF6B5B), markedBg: .hex(0x2A1D1B),
        cursor: .hex(0x2F5FA8), cursorInactive: .hex(0x2C3E5C),
        accent: .hex(0x4C8DFF), fnKey: .hex(0x2B2D31), hover: .hex(0x26282D),
        toggled: .hex(0xFF9130), good: .hex(0x7AC88A))

    static let light = Palette(
        window: .hex(0xF0F0F3), panel: .hex(0xFFFFFF), header: .hex(0xE4E6EA),
        border: .hex(0xB9BDC4), borderActive: .hex(0x1F6FD0),
        text: .hex(0x1B1D20), textDim: .hex(0x63696F),
        marked: .hex(0xC0392B), markedBg: .hex(0xFCE9E6),
        cursor: .hex(0xBBD6F5), cursorInactive: .hex(0xD6E4F5),
        accent: .hex(0x1F6FD0), fnKey: .hex(0xE4E6EA), hover: .hex(0xD6DAE0),
        toggled: .hex(0xD2691E), good: .hex(0x1E7B34))

    static func of(_ theme: AppTheme) -> Palette { theme == .dark ? .dark : .light }
}

extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }

    var swiftUI: Color { Color(nsColor: self) }
}

/// The interface size, in steps of a quarter from 75% to 200%.
enum UIScale {
    static let ladder: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// The rung nearest a value, for one that came from somewhere less tidy.
    static func nearest(_ scale: Double) -> Double {
        ladder.min(by: { abs($0 - scale) < abs($1 - scale) }) ?? 1.0
    }

    static func step(from scale: Double, by direction: Int) -> Double {
        let index = ladder.firstIndex(of: nearest(scale)) ?? 1
        return ladder[min(max(index + direction, 0), ladder.count - 1)]
    }
}

/// What every view needs to draw itself: the colours and the interface size. SwiftUI has
/// no layout transform, so instead of scaling the window as WPF does, every size and font
/// goes through `s(_:)` and is laid out afresh at the new size - text stays sharp and
/// nothing overlaps.
struct UI {
    var palette: Palette = .dark
    var scale: Double = 1.0

    func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    func nsFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * scale, weight: weight)
    }

    func nsMono(_ size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size * scale, weight: .regular)
    }

    var text: Color { palette.text.swiftUI }
    var dim: Color { palette.textDim.swiftUI }
    var header: Color { palette.header.swiftUI }
    var border: Color { palette.border.swiftUI }
    var accent: Color { palette.accent.swiftUI }
    var window: Color { palette.window.swiftUI }
    var panel: Color { palette.panel.swiftUI }
    var hover: Color { palette.hover.swiftUI }
    var toggled: Color { palette.toggled.swiftUI }
    var marked: Color { palette.marked.swiftUI }
}

private struct UIKey: EnvironmentKey {
    static let defaultValue = UI()
}

extension EnvironmentValues {
    var ui: UI {
        get { self[UIKey.self] }
        set { self[UIKey.self] = newValue }
    }
}

/// The app's ordinary button: header background, thin border, accent border on hover and
/// an accent fill while pressed. Never takes the keyboard, so pressing one does not pull
/// focus out of the pane being worked in.
struct DazButtonStyle: ButtonStyle {
    var background: Color? = nil
    var foreground: Color? = nil
    /// Toggled buttons draw a thicker orange border that hover does not paint over.
    var toggled = false
    var padding = EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let style: DazButtonStyle
        @Environment(\.ui) private var ui
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let fill: Color = configuration.isPressed && !style.toggled ? ui.accent
                : hovering ? ui.hover
                : (style.background ?? ui.header)
            let edge: Color = style.toggled ? ui.toggled : hovering ? ui.accent : ui.border
            configuration.label
                .font(ui.font(12))
                .foregroundStyle(!isEnabled ? ui.dim
                                 : style.toggled ? ui.toggled
                                 : (style.foreground ?? ui.text))
                .padding(EdgeInsets(top: ui.s(style.padding.top), leading: ui.s(style.padding.leading),
                                    bottom: ui.s(style.padding.bottom), trailing: ui.s(style.padding.trailing)))
                .background(fill)
                .overlay(Rectangle().strokeBorder(edge, lineWidth: style.toggled ? 2 : 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

extension View {
    /// A bordered strip of the header colour, as every bar in the window is drawn.
    func barBackground(_ ui: UI, highlighted: Bool = false) -> some View {
        background(ui.header)
            .overlay(Rectangle().strokeBorder(highlighted ? ui.accent : ui.border, lineWidth: 1))
    }
}

/// A stroked vector glyph, drawn in a 24-unit box like the WPF paths it came from.
struct Glyph: Shape {
    let draw: @Sendable (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var path = Path()
        draw(&path)
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: (rect.width / scale - 24) / 2, y: (rect.height / scale - 24) / 2))
    }

    /// The pencil on the rearrange buttons.
    static let pencil = Glyph { p in
        p.move(to: .init(x: 4, y: 20)); p.addLine(to: .init(x: 4, y: 16))
        p.addLine(to: .init(x: 15.5, y: 4.5)); p.addLine(to: .init(x: 19.5, y: 8.5))
        p.addLine(to: .init(x: 8, y: 20)); p.closeSubpath()
        p.move(to: .init(x: 13.5, y: 6.5)); p.addLine(to: .init(x: 17.5, y: 10.5))
    }

    static let plus = Glyph { p in
        p.move(to: .init(x: 5, y: 12)); p.addLine(to: .init(x: 19, y: 12))
        p.move(to: .init(x: 12, y: 5)); p.addLine(to: .init(x: 12, y: 19))
    }

    static let minus = Glyph { p in
        p.move(to: .init(x: 5, y: 12)); p.addLine(to: .init(x: 19, y: 12))
    }

    static let magnifier = Glyph { p in
        p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 14, height: 14))
        p.move(to: .init(x: 15.6, y: 15.6)); p.addLine(to: .init(x: 20.5, y: 20.5))
    }

    /// Match: two level bars.
    static let match = Glyph { p in
        p.move(to: .init(x: 3, y: 9)); p.addLine(to: .init(x: 21, y: 9))
        p.move(to: .init(x: 3, y: 15)); p.addLine(to: .init(x: 21, y: 15))
    }

    /// Jump to folder: an arrow pointing down.
    static let downArrow = Glyph { p in
        p.move(to: .init(x: 12, y: 3)); p.addLine(to: .init(x: 12, y: 19))
        p.move(to: .init(x: 4.5, y: 12)); p.addLine(to: .init(x: 12, y: 19.5))
        p.addLine(to: .init(x: 19.5, y: 12))
    }

    /// ".." in the file list.
    static let upArrow = Glyph { p in
        p.move(to: .init(x: 12, y: 20)); p.addLine(to: .init(x: 12, y: 4.5))
        p.move(to: .init(x: 5.25, y: 11.25)); p.addLine(to: .init(x: 12, y: 4.5))
        p.addLine(to: .init(x: 18.75, y: 11.25))
    }
}

/// The filled icons traced from DAZ Commander's buttons folder: pack, unpack, gear.
enum FilledIcon {
    /// Arrow down into a tray, in a 512 box.
    static func zip(in rect: CGRect) -> Path { tray(rect, arrowDown: true) }
    /// The same tray with the arrow coming up out of it.
    static func unzip(in rect: CGRect) -> Path { tray(rect, arrowDown: false) }

    private static func tray(_ rect: CGRect, arrowDown: Bool) -> Path {
        var p = Path()
        // the tray
        p.move(to: .init(x: 480, y: 224))
        p.addCurve(to: .init(x: 448, y: 256), control1: .init(x: 462.3, y: 224), control2: .init(x: 448, y: 238.3))
        p.addLine(to: .init(x: 448, y: 448)); p.addLine(to: .init(x: 64, y: 448)); p.addLine(to: .init(x: 64, y: 256))
        p.addCurve(to: .init(x: 0, y: 256), control1: .init(x: 64, y: 213.3), control2: .init(x: 0, y: 213.3))
        p.addLine(to: .init(x: 0, y: 480))
        p.addCurve(to: .init(x: 32, y: 512), control1: .init(x: 0, y: 497.7), control2: .init(x: 14.3, y: 512))
        p.addLine(to: .init(x: 480, y: 512))
        p.addCurve(to: .init(x: 512, y: 480), control1: .init(x: 497.7, y: 512), control2: .init(x: 512, y: 497.7))
        p.addLine(to: .init(x: 512, y: 256))
        p.addCurve(to: .init(x: 480, y: 224), control1: .init(x: 512, y: 238.3), control2: .init(x: 497.7, y: 224))
        p.closeSubpath()
        if arrowDown {
            p.move(to: .init(x: 288, y: 224)); p.addLine(to: .init(x: 288, y: 28))
            p.addCurve(to: .init(x: 224, y: 28), control1: .init(x: 288, y: -9), control2: .init(x: 224, y: -9))
            p.addLine(to: .init(x: 224, y: 224)); p.addLine(to: .init(x: 128, y: 224))
            p.addLine(to: .init(x: 256, y: 352)); p.addLine(to: .init(x: 384, y: 224)); p.closeSubpath()
        } else {
            p.move(to: .init(x: 224, y: 128)); p.addLine(to: .init(x: 224, y: 324))
            p.addCurve(to: .init(x: 288, y: 324), control1: .init(x: 224, y: 361), control2: .init(x: 288, y: 361))
            p.addLine(to: .init(x: 288, y: 128)); p.addLine(to: .init(x: 384, y: 128))
            p.addLine(to: .init(x: 256, y: 0)); p.addLine(to: .init(x: 128, y: 128)); p.closeSubpath()
        }
        let scale = min(rect.width, rect.height) / 512
        return p.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}

struct TrayIcon: Shape {
    let down: Bool
    func path(in rect: CGRect) -> Path { down ? FilledIcon.zip(in: rect) : FilledIcon.unzip(in: rect) }
}
