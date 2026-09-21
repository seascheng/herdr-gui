import Foundation

// MARK: - cell canvas theme (colors as packed 0x00RRGGBB)
//
// Color packing on the wire (herdr-gpui terminal.rs):
//   value>>24 == 0: 1..=16 → named palette[n-1]; 0/other → default
//   value>>24 == 1: indexed palette[value & 255]
//   value>>24 == 2: RGB value & 0xffffff
// Modifier bits: bold=1 dim=2 italic=4 underline=8 reversed=64
//                hidden=128 strikethrough=256

struct CellTheme {
    var foreground: UInt32
    var background: UInt32
    var cursor: UInt32
    /// 256 entries: 16 ANSI (theme) + 216 cube + 24 grayscale.
    var palette: [UInt32]

    /// Cell modifier bit values (crossterm-compatible order).
    static let bold: UInt16 = 1
    static let dim: UInt16 = 1 << 1
    static let italic: UInt16 = 1 << 2
    static let underline: UInt16 = 1 << 3
    static let reversed: UInt16 = 1 << 6
    static let hidden: UInt16 = 1 << 7
    static let strikethrough: UInt16 = 1 << 8

    static func resolveColor(_ value: UInt32, default fallback: UInt32,
                             theme: CellTheme) -> UInt32 {
        switch value >> 24 {
        case 0:
            let index = value & 255
            return (1...16).contains(index) ? theme.palette[Int(index) - 1] : fallback
        case 1:
            return theme.palette[Int(value & 255)]
        case 2:
            return value & 0xffffff
        default:
            return fallback
        }
    }

    /// Final (fg, bg) after reverse/dim/hidden blending.
    func cellColors(_ cell: CellData) -> (fg: UInt32, bg: UInt32) {
        var fg = Self.resolveColor(cell.fg, default: foreground, theme: self)
        var bg = Self.resolveColor(cell.bg, default: background, theme: self)
        if cell.modifier & Self.reversed != 0 {
            swap(&fg, &bg)
        }
        if cell.modifier & Self.dim != 0 {
            fg = ((fg & 0xfefefe) >> 1) + ((bg & 0xfefefe) >> 1)
        }
        if cell.modifier & Self.hidden != 0 {
            fg = bg
        }
        return (fg, bg)
    }

    /// Shape-affecting style: only bold/italic change glyph selection.
    func shapeKey(_ cell: CellData) -> UInt32 {
        cellColors(cell).fg | (UInt32(cell.modifier & (Self.bold | Self.italic)) << 24)
    }

    // MARK: Construction

    /// Neutral dark defaults with the standard xterm-256 extensions; the
    /// app overlays its theme's 16 ANSI entries at runtime.
    static let defaults: CellTheme = {
        let ansi: [UInt32] = [
            0x1b1d21, 0xb04040, 0x50a14f, 0x987655, 0x4078f2, 0xa626a4,
            0x0184bc, 0xa0a1a7, 0x67696e, 0xe45649, 0x67b845, 0xc18401,
            0x4078f2, 0xa626a4, 0x0184bc, 0xfaFAfa & 0xfafafa,
        ]
        return CellTheme(ansi16: ansi, foreground: 0xd8dee9, background: 0x101419,
                         cursor: 0xd8dee9)
    }()

    init(ansi16: [UInt32], foreground: UInt32, background: UInt32, cursor: UInt32) {
        precondition(ansi16.count == 16)
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        var palette = ansi16
        palette.reserveCapacity(256)
        // xterm 6x6x6 color cube, indexes 16..231.
        let levels: [UInt32] = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
        for r in levels {
            for g in levels {
                for b in levels {
                    palette.append(r << 16 | g << 8 | b)
                }
            }
        }
        // Grayscale ramp, indexes 232..255.
        for i in 0..<24 {
            let v = UInt32(8 + 10 * i)
            palette.append(v << 16 | v << 8 | v)
        }
        self.palette = palette
    }
}
