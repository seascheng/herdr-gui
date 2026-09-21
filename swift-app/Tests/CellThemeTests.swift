import Foundation

/// Color resolution rules from herdr-gpui terminal.rs `color`/`cellColors`,
/// plus xterm-256 palette construction.
enum CellThemeTests {
    static func register() {
        let ok1 = TestRegistry.add("theme: 256-entry palette structure") {
            let theme = CellTheme.defaults
            expectEq(theme.palette.count, 256, "palette size")
            // 6x6x6 cube spot checks (index 16 + 36r + 6g + b).
            expectEq(theme.palette[16], 0x000000, "cube 0,0,0")
            expectEq(theme.palette[17], 0x00005f, "cube 0,0,1")
            expectEq(theme.palette[21], 0x0000ff, "cube 0,0,5")
            expectEq(theme.palette[196], 0xff0000, "cube 5,0,0")
            expectEq(theme.palette[231], 0xffffff, "cube 5,5,5")
            // Grayscale ramp 232..255: 8 + 10*i.
            expectEq(theme.palette[232], 0x080808, "gray 0")
            expectEq(theme.palette[244], 0x808080, "gray 12")
            expectEq(theme.palette[255], 0xeeeeee, "gray 23")
        }
        let ok2 = TestRegistry.add("theme: packed color resolution") {
            let theme = CellTheme.defaults
            // Named 1..=16 → palette[n-1].
            expectEq(CellTheme.resolveColor(1, default: 0xdeadbeef, theme: theme),
                     theme.palette[0], "named 1")
            expectEq(CellTheme.resolveColor(16, default: 0xdeadbeef, theme: theme),
                     theme.palette[15], "named 16")
            // 0 and >16 in the low byte of a 0-tagged value → default.
            expectEq(CellTheme.resolveColor(0, default: 0xdeadbeef, theme: theme),
                     0xdeadbeef, "zero → default")
            expectEq(CellTheme.resolveColor(17, default: 0xdeadbeef, theme: theme),
                     0xdeadbeef, "17 → default")
            // Indexed 0x01xxxxxx → palette[low byte].
            expectEq(CellTheme.resolveColor(0x0100c8, default: 0, theme: theme),
                     theme.palette[200], "indexed 200")
            expectEq(CellTheme.resolveColor(0x0100ff, default: 0, theme: theme),
                     theme.palette[255], "indexed 255")
            // RGB 0x02RRGGBB.
            expectEq(CellTheme.resolveColor(0x02ab12cd, default: 0, theme: theme),
                     0xab12cd, "rgb")
            // Unknown tag → default.
            expectEq(CellTheme.resolveColor(0x03ff00ff, default: 0x123456, theme: theme),
                     0x123456, "unknown tag → default")
        }
        let ok3 = TestRegistry.add("theme: modifier blending") {
            let theme = CellTheme.defaults
            func cell(fg: UInt32, bg: UInt32, modifier: UInt16) -> CellData {
                CellData(symbol: "x", fg: fg, bg: bg, modifier: modifier,
                         skip: false, hyperlink: nil)
            }
            // Plain: theme defaults for 0 colors.
            let plain = theme.cellColors(cell(fg: 0, bg: 0, modifier: 0))
            expectEq(plain.fg, theme.foreground, "default fg")
            expectEq(plain.bg, theme.background, "default bg")
            // Reverse swaps.
            let rev = theme.cellColors(cell(fg: 0x02aa0000, bg: 0x0200bb00, modifier: 64))
            expectEq(rev.fg, 0x00bb00, "reverse fg")
            expectEq(rev.bg, 0xaa0000, "reverse bg")
            // Dim: fg blended halfway toward bg.
            let dim = theme.cellColors(cell(fg: 0x02ffffff, bg: 0x02000000, modifier: 2))
            expectEq(dim.fg, 0x7f7f7f, "dim blend")
            // Hidden: fg = bg.
            let hidden = theme.cellColors(cell(fg: 0x02ff0000, bg: 0x0200ff00, modifier: 128))
            expectEq(hidden.fg, 0x00ff00, "hidden fg = bg")
        }
        expect(ok1 && ok2 && ok3, "registration")
    }
}
