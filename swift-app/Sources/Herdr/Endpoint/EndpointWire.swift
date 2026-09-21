import Foundation

// MARK: - herdr endpoint wire types (generation 1)
//
// Vendored mirror of herdr's `src/protocol/wire.rs` (herdrdev/herdr @
// 856b64b9, Apache-2.0; via penso/herdr-gpui's client-side adaptation).
// Field and variant order are compatibility contracts: bincode uses
// positional encoding, so NOTHING here may be reordered. Variant indices
// are 0-based declaration order.

// MARK: Wire writer (bincode 2 `standard`: LE, prefix varints)

struct WireWriter {
    private(set) var buf: [UInt8] = []

    mutating func u8(_ v: UInt8) { buf.append(v) }
    mutating func bool(_ v: Bool) { buf.append(v ? 1 : 0) }

    private mutating func prefixVarint(_ value: UInt64) {
        if value <= 250 {
            buf.append(UInt8(truncatingIfNeeded: value))
        } else if value <= UInt64(UInt16.max) {
            buf.append(251)
            let v = UInt16(truncatingIfNeeded: value)
            buf.append(UInt8(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: v >> 8))
        } else if value <= UInt64(UInt32.max) {
            buf.append(252)
            let v = UInt32(truncatingIfNeeded: value)
            for shift in stride(from: 0, through: 24, by: 8) {
                buf.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
            }
        } else {
            buf.append(253)
            for shift in stride(from: 0, through: 56, by: 8) {
                buf.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
        }
    }

    mutating func u16(_ v: UInt16) { prefixVarint(UInt64(v)) }
    mutating func u32(_ v: UInt32) { prefixVarint(UInt64(v)) }
    mutating func u64(_ v: UInt64) { prefixVarint(v) }
    mutating func usize(_ v: Int) { prefixVarint(UInt64(v)) }
    mutating func i32(_ v: Int32) { prefixVarint(UInt64(bitPattern: Int64(v))) }

    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        prefixVarint(UInt64(utf8.count))
        buf.append(contentsOf: utf8)
    }

    mutating func bytes(_ b: [UInt8]) {
        prefixVarint(UInt64(b.count))
        buf.append(contentsOf: b)
    }

    mutating func variant(_ index: UInt32) { prefixVarint(UInt64(index)) }

    /// bincode encodes `char` as a u32 codepoint.
    mutating func char(_ c: Character) {
        u32(UInt32(c.unicodeScalars.first?.value ?? 0))
    }
}

enum EndpointWireError: Error {
    case truncated
    case badVariant(String, UInt64)
    case trailingBytes
    // Frame invariants (frame.rs).
    case cellCount
    case hyperlinkIndex
    case cursorBounds
    case patchIdentity
    case patchRowBounds
    case patchGeometry
}

// MARK: - Small shared types

struct ClientSurfaceSize: Equatable, Codable {
    var cols: UInt16
    var rows: UInt16
    init(cols: UInt16, rows: UInt16) { self.cols = cols; self.rows = rows }
    enum CodingKeys: String, CodingKey { case cols, rows }
    func encode(to w: inout WireWriter) { w.u16(cols); w.u16(rows) }
    init(from r: inout BincodeReader) throws {
        cols = try r.readU16(); rows = try r.readU16()
    }
}

enum RenderEncoding: Equatable {
    case semanticFrame, terminalAnsi
    func encode(to w: inout WireWriter) {
        switch self {
        case .semanticFrame: w.variant(0)
        case .terminalAnsi: w.variant(1)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .semanticFrame
        case 1: self = .terminalAnsi
        case let v: throw EndpointWireError.badVariant("RenderEncoding", v)
        }
    }
}

// MARK: - Input family

enum ClientKeyKind: Equatable {
    case press, `repeat`, release
    func encode(to w: inout WireWriter) {
        switch self {
        case .press: w.variant(0)
        case .`repeat`: w.variant(1)
        case .release: w.variant(2)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .press
        case 1: self = .`repeat`
        case 2: self = .release
        case let v: throw EndpointWireError.badVariant("ClientKeyKind", v)
        }
    }
}

enum ClientKeyCode: Equatable, Hashable {
    case backspace, enter, left, right, up, down, home, end, pageUp, pageDown
    case tab, backTab, delete, insert, esc
    case char(Character)
    case f(UInt8)
    case null

    func encode(to w: inout WireWriter) {
        switch self {
        case .backspace: w.variant(0)
        case .enter: w.variant(1)
        case .left: w.variant(2)
        case .right: w.variant(3)
        case .up: w.variant(4)
        case .down: w.variant(5)
        case .home: w.variant(6)
        case .end: w.variant(7)
        case .pageUp: w.variant(8)
        case .pageDown: w.variant(9)
        case .tab: w.variant(10)
        case .backTab: w.variant(11)
        case .delete: w.variant(12)
        case .insert: w.variant(13)
        case .esc: w.variant(14)
        case .char(let c): w.variant(15); w.char(c)
        case .f(let n): w.variant(16); w.u8(n)
        case .null: w.variant(17)
        }
    }

    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .backspace
        case 1: self = .enter
        case 2: self = .left
        case 3: self = .right
        case 4: self = .up
        case 5: self = .down
        case 6: self = .home
        case 7: self = .end
        case 8: self = .pageUp
        case 9: self = .pageDown
        case 10: self = .tab
        case 11: self = .backTab
        case 12: self = .delete
        case 13: self = .insert
        case 14: self = .esc
        case 15: self = .char(Character(Unicode.Scalar(UInt32(try r.readU32())) ?? "?"))
        case 16: self = .f(try r.readVarintU8())
        case 17: self = .null
        case let v: throw EndpointWireError.badVariant("ClientKeyCode", v)
        }
    }
}

enum ClientMouseButton: Equatable {
    case left, right, middle
    func encode(to w: inout WireWriter) {
        switch self {
        case .left: w.variant(0)
        case .right: w.variant(1)
        case .middle: w.variant(2)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .middle
        case let v: throw EndpointWireError.badVariant("ClientMouseButton", v)
        }
    }
}

enum ClientMouseKind: Equatable {
    case down(ClientMouseButton), up(ClientMouseButton), drag(ClientMouseButton)
    case moved, scrollUp, scrollDown, scrollLeft, scrollRight

    func encode(to w: inout WireWriter) {
        switch self {
        case .down(let b): w.variant(0); b.encode(to: &w)
        case .up(let b): w.variant(1); b.encode(to: &w)
        case .drag(let b): w.variant(2); b.encode(to: &w)
        case .moved: w.variant(3)
        case .scrollUp: w.variant(4)
        case .scrollDown: w.variant(5)
        case .scrollLeft: w.variant(6)
        case .scrollRight: w.variant(7)
        }
    }

    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .down(try ClientMouseButton(from: &r))
        case 1: self = .up(try ClientMouseButton(from: &r))
        case 2: self = .drag(try ClientMouseButton(from: &r))
        case 3: self = .moved
        case 4: self = .scrollUp
        case 5: self = .scrollDown
        case 6: self = .scrollLeft
        case 7: self = .scrollRight
        case let v: throw EndpointWireError.badVariant("ClientMouseKind", v)
        }
    }
}

enum ClientMousePosition: Equatable {
    case cell(column: UInt16, row: UInt16)
    case pixels(x: UInt32, y: UInt32, column: UInt16, row: UInt16)

    func encode(to w: inout WireWriter) {
        switch self {
        case .cell(let column, let row):
            w.variant(0); w.u16(column); w.u16(row)
        case .pixels(let x, let y, let column, let row):
            w.variant(1); w.u32(x); w.u32(y); w.u16(column); w.u16(row)
        }
    }

    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .cell(column: try r.readU16(), row: try r.readU16())
        case 1: self = .pixels(x: try r.readU32(), y: try r.readU32(),
                               column: try r.readU16(), row: try r.readU16())
        case let v: throw EndpointWireError.badVariant("ClientMousePosition", v)
        }
    }
}

struct ClientMouseGeometry: Equatable {
    var cols: UInt16, rows: UInt16
    var widthPx: UInt32, heightPx: UInt32
    init(cols: UInt16, rows: UInt16, widthPx: UInt32, heightPx: UInt32) {
        self.cols = cols; self.rows = rows; self.widthPx = widthPx; self.heightPx = heightPx
    }
    func encode(to w: inout WireWriter) {
        w.u16(cols); w.u16(rows); w.u32(widthPx); w.u32(heightPx)
    }
    init(from r: inout BincodeReader) throws {
        cols = try r.readU16(); rows = try r.readU16()
        widthPx = try r.readU32(); heightPx = try r.readU32()
    }
}

struct WindowsKeyRecord: Equatable {
    var keyDown: Bool
    var repeatCount: UInt16
    var virtualKeyCode: UInt16
    var virtualScanCode: UInt16
    var unicode: UInt16
    var controlKeyState: UInt32
    init(keyDown: Bool, repeatCount: UInt16, virtualKeyCode: UInt16,
         virtualScanCode: UInt16, unicode: UInt16, controlKeyState: UInt32) {
        self.keyDown = keyDown; self.repeatCount = repeatCount
        self.virtualKeyCode = virtualKeyCode; self.virtualScanCode = virtualScanCode
        self.unicode = unicode; self.controlKeyState = controlKeyState
    }
    func encode(to w: inout WireWriter) {
        w.bool(keyDown); w.u16(repeatCount); w.u16(virtualKeyCode)
        w.u16(virtualScanCode); w.u16(unicode); w.u32(controlKeyState)
    }
    init(from r: inout BincodeReader) throws {
        keyDown = try r.readBool(); repeatCount = try r.readU16()
        virtualKeyCode = try r.readU16(); virtualScanCode = try r.readU16()
        unicode = try r.readU16(); controlKeyState = try r.readU32()
    }
}

enum ClientPaneInputEvent: Equatable {
    case key(code: ClientKeyCode, modifiers: UInt8, kind: ClientKeyKind,
             repeatCount: UInt16, shiftedCodepoint: UInt32?,
             generatedText: String?, tracksRelease: Bool,
             physicalKeyId: UInt32?, windowsRecord: WindowsKeyRecord?)
    case textCommit(String)
    case mouse(kind: ClientMouseKind, position: ClientMousePosition,
               geometry: ClientMouseGeometry?, modifiers: UInt8, lines: UInt16)
    case paste(String)

    func encode(to w: inout WireWriter) {
        switch self {
        case let .key(code, modifiers, kind, repeatCount, shifted, generated,
                      tracks, physical, windows):
            w.variant(0)
            code.encode(to: &w); w.u8(modifiers); kind.encode(to: &w)
            w.u16(repeatCount)
            if let shifted { w.bool(true); w.u32(shifted) } else { w.bool(false) }
            if let generated { w.bool(true); w.string(generated) } else { w.bool(false) }
            w.bool(tracks)
            if let physical { w.bool(true); w.u32(physical) } else { w.bool(false) }
            if let windows { w.bool(true); windows.encode(to: &w) } else { w.bool(false) }
        case .textCommit(let text):
            w.variant(1); w.string(text)
        case let .mouse(kind, position, geometry, modifiers, lines):
            w.variant(2)
            kind.encode(to: &w); position.encode(to: &w)
            if let geometry { w.bool(true); geometry.encode(to: &w) } else { w.bool(false) }
            w.u8(modifiers); w.u16(lines)
        case .paste(let text):
            w.variant(3); w.string(text)
        }
    }

    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0:
            let code = try ClientKeyCode(from: &r)
            let modifiers = try r.readVarintU8()
            let kind = try ClientKeyKind(from: &r)
            let repeatCount = try r.readU16()
            let shifted = try r.readBool() ? try r.readU32() : nil
            let generated = try r.readBool() ? try r.readString() : nil
            let tracks = try r.readBool()
            let physical = try r.readBool() ? try r.readU32() : nil
            let windows = try r.readBool() ? try WindowsKeyRecord(from: &r) : nil
            self = .key(code: code, modifiers: modifiers, kind: kind,
                        repeatCount: repeatCount, shiftedCodepoint: shifted,
                        generatedText: generated, tracksRelease: tracks,
                        physicalKeyId: physical, windowsRecord: windows)
        case 1:
            self = .textCommit(try r.readString())
        case 2:
            let kind = try ClientMouseKind(from: &r)
            let position = try ClientMousePosition(from: &r)
            let geometry = try r.readBool() ? try ClientMouseGeometry(from: &r) : nil
            let modifiers = try r.readVarintU8()
            let lines = try r.readU16()
            self = .mouse(kind: kind, position: position, geometry: geometry,
                          modifiers: modifiers, lines: lines)
        case 3:
            self = .paste(try r.readString())
        case let v:
            throw EndpointWireError.badVariant("ClientPaneInputEvent", v)
        }
    }
}

// MARK: - Host theme / clipboard targets / scroll attachments

struct ClientHostColor: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    func encode(to w: inout WireWriter) { w.u8(r); w.u8(g); w.u8(b) }
    init(from r: inout BincodeReader) throws {
        self.r = try r.readVarintU8()
        self.g = try r.readVarintU8()
        self.b = try r.readVarintU8()
    }
}

enum ClientHostDefaultColorKind: Equatable {
    case foreground, background
    func encode(to w: inout WireWriter) {
        switch self { case .foreground: w.variant(0); case .background: w.variant(1) }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .foreground
        case 1: self = .background
        case let v: throw EndpointWireError.badVariant("ClientHostDefaultColorKind", v)
        }
    }
}

enum ClientHostAppearance: Equatable {
    case dark, light
    func encode(to w: inout WireWriter) {
        switch self { case .dark: w.variant(0); case .light: w.variant(1) }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .dark
        case 1: self = .light
        case let v: throw EndpointWireError.badVariant("ClientHostAppearance", v)
        }
    }
}

enum ClientHostThemeUpdate {
    case defaultColor(kind: ClientHostDefaultColorKind, color: ClientHostColor)
    case paletteColors([(UInt8, ClientHostColor)])
    case appearance(ClientHostAppearance)

    func encode(to w: inout WireWriter) {
        switch self {
        case let .defaultColor(kind, color):
            w.variant(0); kind.encode(to: &w); color.encode(to: &w)
        case .paletteColors(let entries):
            w.variant(1)
            w.usize(entries.count)
            for (index, color) in entries { w.u8(index); color.encode(to: &w) }
        case .appearance(let a):
            w.variant(2); a.encode(to: &w)
        }
    }

    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0:
            self = .defaultColor(kind: try ClientHostDefaultColorKind(from: &r),
                                 color: try ClientHostColor(from: &r))
        case 1:
            let count = try r.readBoundedLengthForEndpoint()
            var entries: [(UInt8, ClientHostColor)] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let index = try r.readVarintU8()
                entries.append((index, try ClientHostColor(from: &r)))
            }
            self = .paletteColors(entries)
        case 2:
            self = .appearance(try ClientHostAppearance(from: &r))
        case let v:
            throw EndpointWireError.badVariant("ClientHostThemeUpdate", v)
        }
    }
}

enum ClientClipboardImageTarget: Equatable {
    case directTerminal
    case pane(String)
    case popup(String)
    func encode(to w: inout WireWriter) {
        switch self {
        case .directTerminal: w.variant(0)
        case .pane(let id): w.variant(1); w.string(id)
        case .popup(let id): w.variant(2); w.string(id)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .directTerminal
        case 1: self = .pane(try r.readString())
        case 2: self = .popup(try r.readString())
        case let v: throw EndpointWireError.badVariant("ClientClipboardImageTarget", v)
        }
    }
}

enum AttachScrollDirection: Equatable {
    case up, down
    func encode(to w: inout WireWriter) {
        switch self { case .up: w.variant(0); case .down: w.variant(1) }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .up
        case 1: self = .down
        case let v: throw EndpointWireError.badVariant("AttachScrollDirection", v)
        }
    }
}

enum AttachScrollSource: Equatable {
    case wheel
    case pageKey(input: [UInt8])
    func encode(to w: inout WireWriter) {
        switch self {
        case .wheel: w.variant(0)
        case .pageKey(let input): w.variant(1); w.bytes(input)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .wheel
        case 1: self = .pageKey(input: try r.readBytes())
        case let v: throw EndpointWireError.badVariant("AttachScrollSource", v)
        }
    }
}

// MARK: - Surface model

struct CellData: Equatable, Hashable {
    var symbol: String
    /// Named color 0..=16; indexed 0x010000XX; RGB 0x02RRGGBB (NOT ARGB).
    var fg: UInt32
    var bg: UInt32
    var modifier: UInt16
    var skip: Bool
    var hyperlink: UInt32?

    init(symbol: String, fg: UInt32, bg: UInt32, modifier: UInt16,
         skip: Bool, hyperlink: UInt32?) {
        self.symbol = symbol; self.fg = fg; self.bg = bg
        self.modifier = modifier; self.skip = skip; self.hyperlink = hyperlink
    }

    func encode(to w: inout WireWriter) {
        w.string(symbol); w.u32(fg); w.u32(bg); w.u16(modifier)
        w.bool(skip)
        if let hyperlink { w.bool(true); w.u32(hyperlink) } else { w.bool(false) }
    }

    init(from r: inout BincodeReader) throws {
        symbol = try r.readString()
        fg = try r.readU32(); bg = try r.readU32()
        modifier = try r.readU16()
        skip = try r.readBool()
        hyperlink = try r.readBool() ? try r.readU32() : nil
    }
}

struct CursorState: Equatable {
    var x: UInt16, y: UInt16
    var visible: Bool
    /// DECSCUSR 0..6.
    var shape: UInt8
    init(x: UInt16, y: UInt16, visible: Bool, shape: UInt8) {
        self.x = x; self.y = y; self.visible = visible; self.shape = shape
    }
    func encode(to w: inout WireWriter) {
        w.u16(x); w.u16(y); w.bool(visible); w.u8(shape)
    }
    init(from r: inout BincodeReader) throws {
        x = try r.readU16(); y = try r.readU16()
        visible = try r.readBool(); shape = try r.readVarintU8()
    }
}

struct FrameData: Equatable {
    var cells: [CellData]
    var width: UInt16, height: UInt16
    var cursor: CursorState?
    var hyperlinks: [String]
    var graphics: [UInt8]

    init(cells: [CellData], width: UInt16, height: UInt16,
         cursor: CursorState?, hyperlinks: [String], graphics: [UInt8]) {
        self.cells = cells; self.width = width; self.height = height
        self.cursor = cursor; self.hyperlinks = hyperlinks; self.graphics = graphics
    }

    /// Surface invariants (frame.rs): exact cell count, hyperlink indices,
    /// cursor bounds. Throwing = reject the frame whole.
    func validate() throws {
        guard cells.count == Int(width) * Int(height) else {
            throw EndpointWireError.cellCount
        }
        for cell in cells {
            if let link = cell.hyperlink, Int(link) >= hyperlinks.count {
                throw EndpointWireError.hyperlinkIndex
            }
        }
        if let cursor, cursor.visible, cursor.x >= width || cursor.y >= height {
            throw EndpointWireError.cursorBounds
        }
    }

    func encode(to w: inout WireWriter) {
        w.usize(cells.count)
        for cell in cells { cell.encode(to: &w) }
        w.u16(width); w.u16(height)
        if let cursor { w.bool(true); cursor.encode(to: &w) } else { w.bool(false) }
        w.usize(hyperlinks.count)
        for link in hyperlinks { w.string(link) }
        w.bytes(graphics)
    }

    init(from r: inout BincodeReader) throws {
        let count = try r.readBoundedLengthForEndpoint()
        var cells: [CellData] = []
        cells.reserveCapacity(count)
        for _ in 0..<count { cells.append(try CellData(from: &r)) }
        self.cells = cells
        width = try r.readU16(); height = try r.readU16()
        cursor = try r.readBool() ? try CursorState(from: &r) : nil
        let linkCount = try r.readBoundedLengthForEndpoint()
        var hyperlinks: [String] = []
        hyperlinks.reserveCapacity(linkCount)
        for _ in 0..<linkCount { hyperlinks.append(try r.readString()) }
        self.hyperlinks = hyperlinks
        graphics = try r.readBytes()
    }
}

struct SurfaceRect: Equatable {
    var x: UInt16, y: UInt16, width: UInt16, height: UInt16
    init(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    func encode(to w: inout WireWriter) {
        w.u16(x); w.u16(y); w.u16(width); w.u16(height)
    }
    init(from r: inout BincodeReader) throws {
        x = try r.readU16(); y = try r.readU16()
        width = try r.readU16(); height = try r.readU16()
    }
}

struct PaneSurfaceScrollMetrics: Equatable {
    var offsetFromBottom: UInt64
    var maxOffsetFromBottom: UInt64
    var viewportRows: UInt64
    init(offsetFromBottom: UInt64, maxOffsetFromBottom: UInt64, viewportRows: UInt64) {
        self.offsetFromBottom = offsetFromBottom
        self.maxOffsetFromBottom = maxOffsetFromBottom
        self.viewportRows = viewportRows
    }
    func encode(to w: inout WireWriter) {
        w.u64(offsetFromBottom); w.u64(maxOffsetFromBottom); w.u64(viewportRows)
    }
    init(from r: inout BincodeReader) throws {
        offsetFromBottom = try r.readU64()
        maxOffsetFromBottom = try r.readU64()
        viewportRows = try r.readU64()
    }
}

struct PaneSurfacePane: Equatable {
    var paneId: String
    var contentRevision: UInt64
    var rect: SurfaceRect
    var innerRect: SurfaceRect
    var scrollbarRect: SurfaceRect?
    var scroll: PaneSurfaceScrollMetrics?
    var focused: Bool
    var mouseReporting: Bool
    var sgrPixelMouse: Bool
    var alternateScreenActive: Bool
    var pixelWidth: UInt32
    var pixelHeight: UInt32

    init(paneId: String, contentRevision: UInt64, rect: SurfaceRect,
         innerRect: SurfaceRect, scrollbarRect: SurfaceRect?,
         scroll: PaneSurfaceScrollMetrics?, focused: Bool,
         mouseReporting: Bool, sgrPixelMouse: Bool,
         alternateScreenActive: Bool, pixelWidth: UInt32, pixelHeight: UInt32) {
        self.paneId = paneId; self.contentRevision = contentRevision
        self.rect = rect; self.innerRect = innerRect
        self.scrollbarRect = scrollbarRect; self.scroll = scroll
        self.focused = focused; self.mouseReporting = mouseReporting
        self.sgrPixelMouse = sgrPixelMouse
        self.alternateScreenActive = alternateScreenActive
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    func encode(to w: inout WireWriter) {
        w.string(paneId); w.u64(contentRevision)
        rect.encode(to: &w); innerRect.encode(to: &w)
        if let scrollbarRect { w.bool(true); scrollbarRect.encode(to: &w) } else { w.bool(false) }
        if let scroll { w.bool(true); scroll.encode(to: &w) } else { w.bool(false) }
        w.bool(focused); w.bool(mouseReporting); w.bool(sgrPixelMouse)
        w.bool(alternateScreenActive)
        w.u32(pixelWidth); w.u32(pixelHeight)
    }

    init(from r: inout BincodeReader) throws {
        paneId = try r.readString()
        contentRevision = try r.readU64()
        rect = try SurfaceRect(from: &r)
        innerRect = try SurfaceRect(from: &r)
        scrollbarRect = try r.readBool() ? try SurfaceRect(from: &r) : nil
        scroll = try r.readBool() ? try PaneSurfaceScrollMetrics(from: &r) : nil
        focused = try r.readBool()
        mouseReporting = try r.readBool()
        sgrPixelMouse = try r.readBool()
        alternateScreenActive = try r.readBool()
        pixelWidth = try r.readU32()
        pixelHeight = try r.readU32()
    }
}

enum PaneSurfaceSplitDirection: Equatable {
    case horizontal, vertical
    func encode(to w: inout WireWriter) {
        switch self { case .horizontal: w.variant(0); case .vertical: w.variant(1) }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .horizontal
        case 1: self = .vertical
        case let v: throw EndpointWireError.badVariant("PaneSurfaceSplitDirection", v)
        }
    }
}

struct PaneSurfaceSplit: Equatable {
    var direction: PaneSurfaceSplitDirection
    var pos: UInt16
    var area: SurfaceRect
    var hitRect: SurfaceRect
    var path: [Bool]
    init(direction: PaneSurfaceSplitDirection, pos: UInt16, area: SurfaceRect,
         hitRect: SurfaceRect, path: [Bool]) {
        self.direction = direction; self.pos = pos
        self.area = area; self.hitRect = hitRect; self.path = path
    }
    func encode(to w: inout WireWriter) {
        direction.encode(to: &w); w.u16(pos)
        area.encode(to: &w); hitRect.encode(to: &w)
        w.usize(path.count)
        for p in path { w.bool(p) }
    }
    init(from r: inout BincodeReader) throws {
        direction = try PaneSurfaceSplitDirection(from: &r)
        pos = try r.readU16()
        area = try SurfaceRect(from: &r)
        hitRect = try SurfaceRect(from: &r)
        let count = try r.readBoundedLengthForEndpoint()
        var path: [Bool] = []
        path.reserveCapacity(count)
        for _ in 0..<count { path.append(try r.readBool()) }
        self.path = path
    }
}

// MARK: - Graphics scene (Phase 1: carried, not rendered)

enum SurfaceGraphicsTarget: Equatable {
    case pane(paneId: String)
    case popup(terminalId: String)
    func encode(to w: inout WireWriter) {
        switch self {
        case .pane(let id): w.variant(0); w.string(id)
        case .popup(let id): w.variant(1); w.string(id)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .pane(paneId: try r.readString())
        case 1: self = .popup(terminalId: try r.readString())
        case let v: throw EndpointWireError.badVariant("SurfaceGraphicsTarget", v)
        }
    }
}

enum SurfaceGraphicsSource: Equatable {
    case terminal(target: SurfaceGraphicsTarget, imageId: UInt32)
    case paneLayer(paneId: String, layerId: String)
    func encode(to w: inout WireWriter) {
        switch self {
        case let .terminal(target, imageId):
            w.variant(0); target.encode(to: &w); w.u32(imageId)
        case let .paneLayer(paneId, layerId):
            w.variant(1); w.string(paneId); w.string(layerId)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .terminal(target: try SurfaceGraphicsTarget(from: &r),
                                 imageId: try r.readU32())
        case 1: self = .paneLayer(paneId: try r.readString(),
                                  layerId: try r.readString())
        case let v: throw EndpointWireError.badVariant("SurfaceGraphicsSource", v)
        }
    }
}

enum SurfaceGraphicsFormat: Equatable {
    case rgb, rgba, png
    func encode(to w: inout WireWriter) {
        switch self { case .rgb: w.variant(0); case .rgba: w.variant(1); case .png: w.variant(2) }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .rgb
        case 1: self = .rgba
        case 2: self = .png
        case let v: throw EndpointWireError.badVariant("SurfaceGraphicsFormat", v)
        }
    }
}

struct SurfaceGraphicsAssetKey: Equatable {
    var source: SurfaceGraphicsSource
    var imageWidth: UInt32, imageHeight: UInt32
    var format: SurfaceGraphicsFormat
    var dataLen: UInt64
    var dataFingerprint: UInt64
    init(source: SurfaceGraphicsSource, imageWidth: UInt32, imageHeight: UInt32,
         format: SurfaceGraphicsFormat, dataLen: UInt64, dataFingerprint: UInt64) {
        self.source = source; self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.format = format; self.dataLen = dataLen; self.dataFingerprint = dataFingerprint
    }
    func encode(to w: inout WireWriter) {
        source.encode(to: &w)
        w.u32(imageWidth); w.u32(imageHeight)
        format.encode(to: &w)
        w.u64(dataLen); w.u64(dataFingerprint)
    }
    init(from r: inout BincodeReader) throws {
        source = try SurfaceGraphicsSource(from: &r)
        imageWidth = try r.readU32(); imageHeight = try r.readU32()
        format = try SurfaceGraphicsFormat(from: &r)
        dataLen = try r.readU64(); dataFingerprint = try r.readU64()
    }
}

struct SurfaceGraphicsAsset: Equatable {
    var key: SurfaceGraphicsAssetKey
    var data: [UInt8]
    init(key: SurfaceGraphicsAssetKey, data: [UInt8]) { self.key = key; self.data = data }
    func encode(to w: inout WireWriter) { key.encode(to: &w); w.bytes(data) }
    init(from r: inout BincodeReader) throws {
        key = try SurfaceGraphicsAssetKey(from: &r)
        data = try r.readBytes()
    }
}

struct SurfaceGraphicsPlacement: Equatable {
    var asset: SurfaceGraphicsAssetKey
    var logicalPlacementId: UInt32
    var x: UInt16, y: UInt16
    var cols: UInt32, rows: UInt32
    var sourceX: UInt32, sourceY: UInt32
    var sourceWidth: UInt32, sourceHeight: UInt32
    var xOffset: UInt32, yOffset: UInt32
    var z: Int32
    var scrollbackOffset: UInt32
    init(asset: SurfaceGraphicsAssetKey, logicalPlacementId: UInt32,
         x: UInt16, y: UInt16, cols: UInt32, rows: UInt32,
         sourceX: UInt32, sourceY: UInt32, sourceWidth: UInt32, sourceHeight: UInt32,
         xOffset: UInt32, yOffset: UInt32, z: Int32, scrollbackOffset: UInt32) {
        self.asset = asset; self.logicalPlacementId = logicalPlacementId
        self.x = x; self.y = y; self.cols = cols; self.rows = rows
        self.sourceX = sourceX; self.sourceY = sourceY
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.xOffset = xOffset; self.yOffset = yOffset
        self.z = z; self.scrollbackOffset = scrollbackOffset
    }
    func encode(to w: inout WireWriter) {
        asset.encode(to: &w); w.u32(logicalPlacementId)
        w.u16(x); w.u16(y); w.u32(cols); w.u32(rows)
        w.u32(sourceX); w.u32(sourceY); w.u32(sourceWidth); w.u32(sourceHeight)
        w.u32(xOffset); w.u32(yOffset); w.i32(z); w.u32(scrollbackOffset)
    }
    init(from r: inout BincodeReader) throws {
        asset = try SurfaceGraphicsAssetKey(from: &r)
        logicalPlacementId = try r.readU32()
        x = try r.readU16(); y = try r.readU16()
        cols = try r.readU32(); rows = try r.readU32()
        sourceX = try r.readU32(); sourceY = try r.readU32()
        sourceWidth = try r.readU32(); sourceHeight = try r.readU32()
        xOffset = try r.readU32(); yOffset = try r.readU32()
        z = Int32(truncatingIfNeeded: try r.readVarint())
        scrollbackOffset = try r.readU32()
    }
}

struct SurfaceGraphicsScene: Equatable {
    var assets: [SurfaceGraphicsAsset]
    var placements: [SurfaceGraphicsPlacement]
    var retainedAssets: [SurfaceGraphicsAssetKey]
    init(assets: [SurfaceGraphicsAsset] = [],
         placements: [SurfaceGraphicsPlacement] = [],
         retainedAssets: [SurfaceGraphicsAssetKey] = []) {
        self.assets = assets; self.placements = placements
        self.retainedAssets = retainedAssets
    }
    func encode(to w: inout WireWriter) {
        w.usize(assets.count)
        for a in assets { a.encode(to: &w) }
        w.usize(placements.count)
        for p in placements { p.encode(to: &w) }
        w.usize(retainedAssets.count)
        for k in retainedAssets { k.encode(to: &w) }
    }
    init(from r: inout BincodeReader) throws {
        let n1 = try r.readBoundedLengthForEndpoint()
        var assets: [SurfaceGraphicsAsset] = []
        for _ in 0..<n1 { assets.append(try SurfaceGraphicsAsset(from: &r)) }
        self.assets = assets
        let n2 = try r.readBoundedLengthForEndpoint()
        var placements: [SurfaceGraphicsPlacement] = []
        for _ in 0..<n2 { placements.append(try SurfaceGraphicsPlacement(from: &r)) }
        self.placements = placements
        let n3 = try r.readBoundedLengthForEndpoint()
        var retained: [SurfaceGraphicsAssetKey] = []
        for _ in 0..<n3 { retained.append(try SurfaceGraphicsAssetKey(from: &r)) }
        self.retainedAssets = retained
    }
}

// MARK: - Snapshot model

enum AgentStatus: Equatable {
    case idle, working, blocked, done, unknown
    func encode(to w: inout WireWriter) {
        switch self {
        case .idle: w.variant(0)
        case .working: w.variant(1)
        case .blocked: w.variant(2)
        case .done: w.variant(3)
        case .unknown: w.variant(4)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .idle
        case 1: self = .working
        case 2: self = .blocked
        case 3: self = .done
        case 4: self = .unknown
        case let v: throw EndpointWireError.badVariant("AgentStatus", v)
        }
    }
}

struct ClientShellProductAnnouncement: Equatable {
    var version: String, id: String, title: String, body: String
    var preview: Bool
    init(version: String, id: String, title: String, body: String, preview: Bool) {
        self.version = version; self.id = id; self.title = title
        self.body = body; self.preview = preview
    }
    func encode(to w: inout WireWriter) {
        w.string(version); w.string(id); w.string(title); w.string(body)
        w.bool(preview)
    }
    init(from r: inout BincodeReader) throws {
        version = try r.readString(); id = try r.readString()
        title = try r.readString(); body = try r.readString()
        preview = try r.readBool()
    }
}

struct ClientShellReleaseNotes: Equatable {
    var version: String, body: String
    var preview: Bool
    init(version: String, body: String, preview: Bool) {
        self.version = version; self.body = body; self.preview = preview
    }
    func encode(to w: inout WireWriter) {
        w.string(version); w.string(body); w.bool(preview)
    }
    init(from r: inout BincodeReader) throws {
        version = try r.readString(); body = try r.readString(); preview = try r.readBool()
    }
}

enum ClientShellCommandAction: Equatable {
    case shell, pane, popup, pluginAction, unknown
    func encode(to w: inout WireWriter) {
        switch self {
        case .shell: w.variant(0)
        case .pane: w.variant(1)
        case .popup: w.variant(2)
        case .pluginAction: w.variant(3)
        case .unknown: w.variant(4)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .shell
        case 1: self = .pane
        case 2: self = .popup
        case 3: self = .pluginAction
        case 4: self = .unknown
        case let v: throw EndpointWireError.badVariant("ClientShellCommandAction", v)
        }
    }
}

struct ClientShellCommand {
    var commandId: String
    var bindingLabel: String
    var bindingLabels: [String]
    var action: ClientShellCommandAction
    var description: String?
    init(commandId: String, bindingLabel: String, bindingLabels: [String],
         action: ClientShellCommandAction, description: String?) {
        self.commandId = commandId; self.bindingLabel = bindingLabel
        self.bindingLabels = bindingLabels; self.action = action
        self.description = description
    }
    func encode(to w: inout WireWriter) {
        w.string(commandId); w.string(bindingLabel)
        w.usize(bindingLabels.count)
        for b in bindingLabels { w.string(b) }
        action.encode(to: &w)
        if let description { w.bool(true); w.string(description) } else { w.bool(false) }
    }
    init(from r: inout BincodeReader) throws {
        commandId = try r.readString()
        bindingLabel = try r.readString()
        let n = try r.readBoundedLengthForEndpoint()
        var bindingLabels: [String] = []
        for _ in 0..<n { bindingLabels.append(try r.readString()) }
        self.bindingLabels = bindingLabels
        action = try ClientShellCommandAction(from: &r)
        description = try r.readBool() ? try r.readString() : nil
    }
}

struct ClientShellTabStatusSegment: Equatable {
    var text: String
    var accent: Bool
    init(text: String, accent: Bool) { self.text = text; self.accent = accent }
    func encode(to w: inout WireWriter) { w.string(text); w.bool(accent) }
    init(from r: inout BincodeReader) throws {
        text = try r.readString(); accent = try r.readBool()
    }
}

struct ClientShellWorktree: Equatable {
    var key: String, label: String
    var isLinkedWorktree: Bool
    init(key: String, label: String, isLinkedWorktree: Bool) {
        self.key = key; self.label = label; self.isLinkedWorktree = isLinkedWorktree
    }
    func encode(to w: inout WireWriter) {
        w.string(key); w.string(label); w.bool(isLinkedWorktree)
    }
    init(from r: inout BincodeReader) throws {
        key = try r.readString(); label = try r.readString()
        isLinkedWorktree = try r.readBool()
    }
}

struct ClientShellWorkspace {
    var workspaceId: String
    var activeTabId: String
    var newWorkspaceCwd: String
    var number: Int
    var label: String
    var customLabel: Bool
    var branch: String?
    var gitAheadBehind: (Int, Int)?
    var tokens: [(String, String)]
    var worktree: ClientShellWorktree?
    var focused: Bool
    var agentStatus: AgentStatus

    init(workspaceId: String, activeTabId: String, newWorkspaceCwd: String,
         number: Int, label: String, customLabel: Bool, branch: String?,
         gitAheadBehind: (Int, Int)?, tokens: [(String, String)],
         worktree: ClientShellWorktree?, focused: Bool, agentStatus: AgentStatus) {
        self.workspaceId = workspaceId; self.activeTabId = activeTabId
        self.newWorkspaceCwd = newWorkspaceCwd; self.number = number
        self.label = label; self.customLabel = customLabel; self.branch = branch
        self.gitAheadBehind = gitAheadBehind; self.tokens = tokens
        self.worktree = worktree; self.focused = focused
        self.agentStatus = agentStatus
    }

    func encode(to w: inout WireWriter) {
        w.string(workspaceId); w.string(activeTabId); w.string(newWorkspaceCwd)
        w.usize(number); w.string(label); w.bool(customLabel)
        if let branch { w.bool(true); w.string(branch) } else { w.bool(false) }
        if let ahead = gitAheadBehind {
            w.bool(true); w.usize(ahead.0); w.usize(ahead.1)
        } else { w.bool(false) }
        w.usize(tokens.count)
        for (k, v) in tokens { w.string(k); w.string(v) }
        if let worktree { w.bool(true); worktree.encode(to: &w) } else { w.bool(false) }
        w.bool(focused); agentStatus.encode(to: &w)
    }

    init(from r: inout BincodeReader) throws {
        workspaceId = try r.readString()
        activeTabId = try r.readString()
        newWorkspaceCwd = try r.readString()
        number = Int(try r.readVarint())
        label = try r.readString()
        customLabel = try r.readBool()
        branch = try r.readBool() ? try r.readString() : nil
        gitAheadBehind = try r.readBool()
            ? (Int(try r.readVarint()), Int(try r.readVarint())) : nil
        let n = try r.readBoundedLengthForEndpoint()
        var tokens: [(String, String)] = []
        for _ in 0..<n { tokens.append((try r.readString(), try r.readString())) }
        self.tokens = tokens
        worktree = try r.readBool() ? try ClientShellWorktree(from: &r) : nil
        focused = try r.readBool()
        agentStatus = try AgentStatus(from: &r)
    }
}

struct ClientShellTab {
    var tabId: String, workspaceId: String
    var number: Int
    var label: String
    var customLabel: Bool
    var zoomed: Bool
    var focused: Bool
    var agentStatus: AgentStatus
    init(tabId: String, workspaceId: String, number: Int, label: String,
         customLabel: Bool, zoomed: Bool, focused: Bool, agentStatus: AgentStatus) {
        self.tabId = tabId; self.workspaceId = workspaceId; self.number = number
        self.label = label; self.customLabel = customLabel; self.zoomed = zoomed
        self.focused = focused; self.agentStatus = agentStatus
    }
    func encode(to w: inout WireWriter) {
        w.string(tabId); w.string(workspaceId); w.usize(number)
        w.string(label); w.bool(customLabel); w.bool(zoomed); w.bool(focused)
        agentStatus.encode(to: &w)
    }
    init(from r: inout BincodeReader) throws {
        tabId = try r.readString(); workspaceId = try r.readString()
        number = Int(try r.readVarint())
        label = try r.readString()
        customLabel = try r.readBool(); zoomed = try r.readBool(); focused = try r.readBool()
        agentStatus = try AgentStatus(from: &r)
    }
}

struct ClientShellPane {
    var paneId: String, workspaceId: String, tabId: String
    var label: String?
    var cwd: String?
    var foregroundCwd: String?
    var focused: Bool
    var rightClickPassthrough: Bool
    init(paneId: String, workspaceId: String, tabId: String, label: String?,
         cwd: String?, foregroundCwd: String?, focused: Bool,
         rightClickPassthrough: Bool) {
        self.paneId = paneId; self.workspaceId = workspaceId; self.tabId = tabId
        self.label = label; self.cwd = cwd; self.foregroundCwd = foregroundCwd
        self.focused = focused; self.rightClickPassthrough = rightClickPassthrough
    }
    func encode(to w: inout WireWriter) {
        w.string(paneId); w.string(workspaceId); w.string(tabId)
        if let label { w.bool(true); w.string(label) } else { w.bool(false) }
        if let cwd { w.bool(true); w.string(cwd) } else { w.bool(false) }
        if let foregroundCwd { w.bool(true); w.string(foregroundCwd) } else { w.bool(false) }
        w.bool(focused); w.bool(rightClickPassthrough)
    }
    init(from r: inout BincodeReader) throws {
        paneId = try r.readString(); workspaceId = try r.readString()
        tabId = try r.readString()
        label = try r.readBool() ? try r.readString() : nil
        cwd = try r.readBool() ? try r.readString() : nil
        foregroundCwd = try r.readBool() ? try r.readString() : nil
        focused = try r.readBool()
        rightClickPassthrough = try r.readBool()
    }
}

struct ClientShellAgent {
    var paneId: String, workspaceId: String, tabId: String
    var name: String?
    var displayAgent: String?
    var agent: String?
    var title: String?
    var terminalTitle: String?
    var terminalTitleStripped: String?
    var agentStatus: AgentStatus
    var stateChangeSeq: UInt64
    var stateLabels: [(String, String)]
    var tokens: [(String, String)]
    var focused: Bool

    init(paneId: String, workspaceId: String, tabId: String, name: String?,
         displayAgent: String?, agent: String?, title: String?,
         terminalTitle: String?, terminalTitleStripped: String?,
         agentStatus: AgentStatus, stateChangeSeq: UInt64,
         stateLabels: [(String, String)], tokens: [(String, String)], focused: Bool) {
        self.paneId = paneId; self.workspaceId = workspaceId; self.tabId = tabId
        self.name = name; self.displayAgent = displayAgent; self.agent = agent
        self.title = title; self.terminalTitle = terminalTitle
        self.terminalTitleStripped = terminalTitleStripped
        self.agentStatus = agentStatus; self.stateChangeSeq = stateChangeSeq
        self.stateLabels = stateLabels; self.tokens = tokens; self.focused = focused
    }

    func encode(to w: inout WireWriter) {
        w.string(paneId); w.string(workspaceId); w.string(tabId)
        if let name { w.bool(true); w.string(name) } else { w.bool(false) }
        if let displayAgent { w.bool(true); w.string(displayAgent) } else { w.bool(false) }
        if let agent { w.bool(true); w.string(agent) } else { w.bool(false) }
        if let title { w.bool(true); w.string(title) } else { w.bool(false) }
        if let terminalTitle { w.bool(true); w.string(terminalTitle) } else { w.bool(false) }
        if let terminalTitleStripped { w.bool(true); w.string(terminalTitleStripped) }
        else { w.bool(false) }
        agentStatus.encode(to: &w)
        w.u64(stateChangeSeq)
        w.usize(stateLabels.count)
        for (k, v) in stateLabels { w.string(k); w.string(v) }
        w.usize(tokens.count)
        for (k, v) in tokens { w.string(k); w.string(v) }
        w.bool(focused)
    }

    init(from r: inout BincodeReader) throws {
        paneId = try r.readString(); workspaceId = try r.readString()
        tabId = try r.readString()
        name = try r.readBool() ? try r.readString() : nil
        displayAgent = try r.readBool() ? try r.readString() : nil
        agent = try r.readBool() ? try r.readString() : nil
        title = try r.readBool() ? try r.readString() : nil
        terminalTitle = try r.readBool() ? try r.readString() : nil
        terminalTitleStripped = try r.readBool() ? try r.readString() : nil
        agentStatus = try AgentStatus(from: &r)
        stateChangeSeq = try r.readU64()
        let n1 = try r.readBoundedLengthForEndpoint()
        var stateLabels: [(String, String)] = []
        for _ in 0..<n1 { stateLabels.append((try r.readString(), try r.readString())) }
        self.stateLabels = stateLabels
        let n2 = try r.readBoundedLengthForEndpoint()
        var tokens: [(String, String)] = []
        for _ in 0..<n2 { tokens.append((try r.readString(), try r.readString())) }
        self.tokens = tokens
        focused = try r.readBool()
    }
}

struct ClientShellSnapshot {
    var bootId: String
    var revision: UInt64
    var configDiagnostic: String?
    var productAnnouncement: ClientShellProductAnnouncement?
    var updateAvailable: String?
    var updateInstallCommand: String
    var serverKeybindingsToml: String?
    var latestReleaseNotesAvailable: Bool
    var integrationUpdatesAvailable: Bool
    var worktreeDirectory: String
    var releaseNotes: ClientShellReleaseNotes?
    var focusedWorkspaceId: String?
    var focusedTabId: String?
    var focusedPaneId: String?
    var tabBarRight: [ClientShellTabStatusSegment]
    var tabBarRightSeparator: String
    var agentViewLabel: String?
    var agentOrder: [String]
    var workspaces: [ClientShellWorkspace]
    var tabs: [ClientShellTab]
    var panes: [ClientShellPane]
    var agents: [ClientShellAgent]
    var commands: [ClientShellCommand]

    init(bootId: String, revision: UInt64, configDiagnostic: String?,
         productAnnouncement: ClientShellProductAnnouncement?,
         updateAvailable: String?, updateInstallCommand: String,
         serverKeybindingsToml: String?, latestReleaseNotesAvailable: Bool,
         integrationUpdatesAvailable: Bool, worktreeDirectory: String,
         releaseNotes: ClientShellReleaseNotes?, focusedWorkspaceId: String?,
         focusedTabId: String?, focusedPaneId: String?,
         tabBarRight: [ClientShellTabStatusSegment], tabBarRightSeparator: String,
         agentViewLabel: String?, agentOrder: [String],
         workspaces: [ClientShellWorkspace], tabs: [ClientShellTab],
         panes: [ClientShellPane], agents: [ClientShellAgent],
         commands: [ClientShellCommand]) {
        self.bootId = bootId; self.revision = revision
        self.configDiagnostic = configDiagnostic
        self.productAnnouncement = productAnnouncement
        self.updateAvailable = updateAvailable
        self.updateInstallCommand = updateInstallCommand
        self.serverKeybindingsToml = serverKeybindingsToml
        self.latestReleaseNotesAvailable = latestReleaseNotesAvailable
        self.integrationUpdatesAvailable = integrationUpdatesAvailable
        self.worktreeDirectory = worktreeDirectory
        self.releaseNotes = releaseNotes
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
        self.tabBarRight = tabBarRight
        self.tabBarRightSeparator = tabBarRightSeparator
        self.agentViewLabel = agentViewLabel
        self.agentOrder = agentOrder
        self.workspaces = workspaces; self.tabs = tabs; self.panes = panes
        self.agents = agents; self.commands = commands
    }

    func encode(to w: inout WireWriter) {
        w.string(bootId); w.u64(revision)
        if let v = configDiagnostic { w.bool(true); w.string(v) } else { w.bool(false) }
        if let v = productAnnouncement { w.bool(true); v.encode(to: &w) } else { w.bool(false) }
        if let v = updateAvailable { w.bool(true); w.string(v) } else { w.bool(false) }
        w.string(updateInstallCommand)
        if let v = serverKeybindingsToml { w.bool(true); w.string(v) } else { w.bool(false) }
        w.bool(latestReleaseNotesAvailable)
        w.bool(integrationUpdatesAvailable)
        w.string(worktreeDirectory)
        if let v = releaseNotes { w.bool(true); v.encode(to: &w) } else { w.bool(false) }
        if let v = focusedWorkspaceId { w.bool(true); w.string(v) } else { w.bool(false) }
        if let v = focusedTabId { w.bool(true); w.string(v) } else { w.bool(false) }
        if let v = focusedPaneId { w.bool(true); w.string(v) } else { w.bool(false) }
        w.usize(tabBarRight.count)
        for s in tabBarRight { s.encode(to: &w) }
        w.string(tabBarRightSeparator)
        if let v = agentViewLabel { w.bool(true); w.string(v) } else { w.bool(false) }
        w.usize(agentOrder.count)
        for a in agentOrder { w.string(a) }
        w.usize(workspaces.count)
        for ws in workspaces { ws.encode(to: &w) }
        w.usize(tabs.count)
        for t in tabs { t.encode(to: &w) }
        w.usize(panes.count)
        for p in panes { p.encode(to: &w) }
        w.usize(agents.count)
        for a in agents { a.encode(to: &w) }
        w.usize(commands.count)
        for c in commands { c.encode(to: &w) }
    }

    init(from r: inout BincodeReader) throws {
        bootId = try r.readString()
        revision = try r.readU64()
        configDiagnostic = try r.readBool() ? try r.readString() : nil
        productAnnouncement = try r.readBool()
            ? try ClientShellProductAnnouncement(from: &r) : nil
        updateAvailable = try r.readBool() ? try r.readString() : nil
        updateInstallCommand = try r.readString()
        serverKeybindingsToml = try r.readBool() ? try r.readString() : nil
        latestReleaseNotesAvailable = try r.readBool()
        integrationUpdatesAvailable = try r.readBool()
        worktreeDirectory = try r.readString()
        releaseNotes = try r.readBool() ? try ClientShellReleaseNotes(from: &r) : nil
        focusedWorkspaceId = try r.readBool() ? try r.readString() : nil
        focusedTabId = try r.readBool() ? try r.readString() : nil
        focusedPaneId = try r.readBool() ? try r.readString() : nil
        let n1 = try r.readBoundedLengthForEndpoint()
        var tabBarRight: [ClientShellTabStatusSegment] = []
        for _ in 0..<n1 { tabBarRight.append(try ClientShellTabStatusSegment(from: &r)) }
        self.tabBarRight = tabBarRight
        tabBarRightSeparator = try r.readString()
        agentViewLabel = try r.readBool() ? try r.readString() : nil
        let n2 = try r.readBoundedLengthForEndpoint()
        var agentOrder: [String] = []
        for _ in 0..<n2 { agentOrder.append(try r.readString()) }
        self.agentOrder = agentOrder
        let n3 = try r.readBoundedLengthForEndpoint()
        var workspaces: [ClientShellWorkspace] = []
        for _ in 0..<n3 { workspaces.append(try ClientShellWorkspace(from: &r)) }
        self.workspaces = workspaces
        let n4 = try r.readBoundedLengthForEndpoint()
        var tabs: [ClientShellTab] = []
        for _ in 0..<n4 { tabs.append(try ClientShellTab(from: &r)) }
        self.tabs = tabs
        let n5 = try r.readBoundedLengthForEndpoint()
        var panes: [ClientShellPane] = []
        for _ in 0..<n5 { panes.append(try ClientShellPane(from: &r)) }
        self.panes = panes
        let n6 = try r.readBoundedLengthForEndpoint()
        var agents: [ClientShellAgent] = []
        for _ in 0..<n6 { agents.append(try ClientShellAgent(from: &r)) }
        self.agents = agents
        let n7 = try r.readBoundedLengthForEndpoint()
        var commands: [ClientShellCommand] = []
        for _ in 0..<n7 { commands.append(try ClientShellCommand(from: &r)) }
        self.commands = commands
    }
}

// MARK: - Surface frames and patches

enum ClientShellPopupSize: Equatable {
    case cells(UInt16)
    case percent(UInt8)
    func encode(to w: inout WireWriter) {
        switch self {
        case .cells(let n): w.variant(0); w.u16(n)
        case .percent(let p): w.variant(1); w.u8(p)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .cells(try r.readU16())
        case 1: self = .percent(try r.readVarintU8())
        case let v: throw EndpointWireError.badVariant("ClientShellPopupSize", v)
        }
    }
}

struct ClientShellPopupSurface {
    var terminalId: String
    var title: String
    var width: ClientShellPopupSize?
    var height: ClientShellPopupSize?
    var frame: FrameData
    var mouseReporting: Bool
    var sgrPixelMouse: Bool
    var pixelWidth: UInt32
    var pixelHeight: UInt32

    init(terminalId: String, title: String, width: ClientShellPopupSize?,
         height: ClientShellPopupSize?, frame: FrameData, mouseReporting: Bool,
         sgrPixelMouse: Bool, pixelWidth: UInt32, pixelHeight: UInt32) {
        self.terminalId = terminalId; self.title = title; self.width = width
        self.height = height; self.frame = frame
        self.mouseReporting = mouseReporting; self.sgrPixelMouse = sgrPixelMouse
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    func encode(to w: inout WireWriter) {
        w.string(terminalId); w.string(title)
        if let width { w.bool(true); width.encode(to: &w) } else { w.bool(false) }
        if let height { w.bool(true); height.encode(to: &w) } else { w.bool(false) }
        frame.encode(to: &w)
        w.bool(mouseReporting); w.bool(sgrPixelMouse)
        w.u32(pixelWidth); w.u32(pixelHeight)
    }

    init(from r: inout BincodeReader) throws {
        terminalId = try r.readString()
        title = try r.readString()
        width = try r.readBool() ? try ClientShellPopupSize(from: &r) : nil
        height = try r.readBool() ? try ClientShellPopupSize(from: &r) : nil
        frame = try FrameData(from: &r)
        mouseReporting = try r.readBool()
        sgrPixelMouse = try r.readBool()
        pixelWidth = try r.readU32()
        pixelHeight = try r.readU32()
    }
}

struct PaneSurfaceFrame {
    var bootId: String
    var projectionRevision: UInt64
    var surfaceRevision: UInt64
    var frame: FrameData
    var panes: [PaneSurfacePane]
    var splits: [PaneSurfaceSplit]
    var popup: ClientShellPopupSurface?
    var graphics: SurfaceGraphicsScene

    init(bootId: String, projectionRevision: UInt64, surfaceRevision: UInt64,
         frame: FrameData, panes: [PaneSurfacePane], splits: [PaneSurfaceSplit],
         popup: ClientShellPopupSurface?, graphics: SurfaceGraphicsScene) {
        self.bootId = bootId
        self.projectionRevision = projectionRevision
        self.surfaceRevision = surfaceRevision
        self.frame = frame; self.panes = panes; self.splits = splits
        self.popup = popup; self.graphics = graphics
    }

    /// Apply a baseline cell patch atomically (frame.rs): either the whole
    /// patch lands or nothing changes and the caller must drop the stream.
    mutating func applyPatch(_ patch: PaneSurfacePatch) throws {
        guard patch.bootId == bootId,
              patch.projectionRevision == projectionRevision,
              patch.baseSurfaceRevision == surfaceRevision,
              surfaceRevision &+ 1 == patch.surfaceRevision,
              popup == nil
        else { throw EndpointWireError.patchIdentity }
        try frame.validate()
        for row in patch.rows {
            if row.y >= frame.height
                || Int(row.x) + row.cells.count > Int(frame.width) {
                throw EndpointWireError.patchRowBounds
            }
            for cell in row.cells {
                if let link = cell.hyperlink, Int(link) >= frame.hyperlinks.count {
                    throw EndpointWireError.hyperlinkIndex
                }
            }
        }
        for pane in patch.panes {
            guard panes.contains(where: {
                $0.paneId == pane.paneId && $0.rect == pane.rect
                    && $0.innerRect == pane.innerRect
            }) else { throw EndpointWireError.patchGeometry }
        }
        if let cursor = patch.cursor,
           cursor.visible, cursor.x >= frame.width || cursor.y >= frame.height {
            throw EndpointWireError.cursorBounds
        }
        for row in patch.rows {
            let start = Int(row.y) * Int(frame.width) + Int(row.x)
            frame.cells.replaceSubrange(start..<(start + row.cells.count), with: row.cells)
        }
        for pane in patch.panes {
            if let index = panes.firstIndex(where: { $0.paneId == pane.paneId }) {
                panes[index] = pane
            }
        }
        frame.cursor = patch.cursor
        surfaceRevision = patch.surfaceRevision
    }

    func encode(to w: inout WireWriter) {
        w.string(bootId); w.u64(projectionRevision); w.u64(surfaceRevision)
        frame.encode(to: &w)
        w.usize(panes.count)
        for p in panes { p.encode(to: &w) }
        w.usize(splits.count)
        for s in splits { s.encode(to: &w) }
        if let popup { w.bool(true); popup.encode(to: &w) } else { w.bool(false) }
        graphics.encode(to: &w)
    }

    init(from r: inout BincodeReader) throws {
        bootId = try r.readString()
        projectionRevision = try r.readU64()
        surfaceRevision = try r.readU64()
        frame = try FrameData(from: &r)
        let n1 = try r.readBoundedLengthForEndpoint()
        var panes: [PaneSurfacePane] = []
        for _ in 0..<n1 { panes.append(try PaneSurfacePane(from: &r)) }
        self.panes = panes
        let n2 = try r.readBoundedLengthForEndpoint()
        var splits: [PaneSurfaceSplit] = []
        for _ in 0..<n2 { splits.append(try PaneSurfaceSplit(from: &r)) }
        self.splits = splits
        popup = try r.readBool() ? try ClientShellPopupSurface(from: &r) : nil
        graphics = try SurfaceGraphicsScene(from: &r)
    }
}

struct PaneSurfacePatchRow {
    var x: UInt16, y: UInt16
    var cells: [CellData]
    init(x: UInt16, y: UInt16, cells: [CellData]) {
        self.x = x; self.y = y; self.cells = cells
    }
    func encode(to w: inout WireWriter) {
        w.u16(x); w.u16(y)
        w.usize(cells.count)
        for cell in cells { cell.encode(to: &w) }
    }
    init(from r: inout BincodeReader) throws {
        x = try r.readU16(); y = try r.readU16()
        let n = try r.readBoundedLengthForEndpoint()
        var cells: [CellData] = []
        cells.reserveCapacity(n)
        for _ in 0..<n { cells.append(try CellData(from: &r)) }
        self.cells = cells
    }
}

struct PaneSurfacePatch {
    var bootId: String
    var projectionRevision: UInt64
    var baseSurfaceRevision: UInt64
    var surfaceRevision: UInt64
    var rows: [PaneSurfacePatchRow]
    var panes: [PaneSurfacePane]
    var cursor: CursorState?

    init(bootId: String, projectionRevision: UInt64, baseSurfaceRevision: UInt64,
         surfaceRevision: UInt64, rows: [PaneSurfacePatchRow],
         panes: [PaneSurfacePane], cursor: CursorState?) {
        self.bootId = bootId
        self.projectionRevision = projectionRevision
        self.baseSurfaceRevision = baseSurfaceRevision
        self.surfaceRevision = surfaceRevision
        self.rows = rows; self.panes = panes; self.cursor = cursor
    }

    func encode(to w: inout WireWriter) {
        w.string(bootId); w.u64(projectionRevision)
        w.u64(baseSurfaceRevision); w.u64(surfaceRevision)
        w.usize(rows.count)
        for row in rows { row.encode(to: &w) }
        w.usize(panes.count)
        for p in panes { p.encode(to: &w) }
        if let cursor { w.bool(true); cursor.encode(to: &w) } else { w.bool(false) }
    }

    init(from r: inout BincodeReader) throws {
        bootId = try r.readString()
        projectionRevision = try r.readU64()
        baseSurfaceRevision = try r.readU64()
        surfaceRevision = try r.readU64()
        let n1 = try r.readBoundedLengthForEndpoint()
        var rows: [PaneSurfacePatchRow] = []
        for _ in 0..<n1 { rows.append(try PaneSurfacePatchRow(from: &r)) }
        self.rows = rows
        let n2 = try r.readBoundedLengthForEndpoint()
        var panes: [PaneSurfacePane] = []
        for _ in 0..<n2 { panes.append(try PaneSurfacePane(from: &r)) }
        self.panes = panes
        cursor = try r.readBool() ? try CursorState(from: &r) : nil
    }
}

// MARK: - Notifications / legacy terminal frames

struct TerminalFrame: Equatable {
    var seq: UInt64
    var width: UInt16, height: UInt16
    var full: Bool
    var bytes: [UInt8]
    init(seq: UInt64, width: UInt16, height: UInt16, full: Bool, bytes: [UInt8]) {
        self.seq = seq; self.width = width; self.height = height
        self.full = full; self.bytes = bytes
    }
    func encode(to w: inout WireWriter) {
        w.u64(seq); w.u16(width); w.u16(height); w.bool(full); w.bytes(bytes)
    }
    init(from r: inout BincodeReader) throws {
        seq = try r.readU64(); width = try r.readU16(); height = try r.readU16()
        full = try r.readBool(); bytes = try r.readBytes()
    }
}

enum NotifyKind: Equatable {
    case sound, toast, systemToast
    func encode(to w: inout WireWriter) {
        switch self {
        case .sound: w.variant(0)
        case .toast: w.variant(1)
        case .systemToast: w.variant(2)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .sound
        case 1: self = .toast
        case 2: self = .systemToast
        case let v: throw EndpointWireError.badVariant("NotifyKind", v)
        }
    }
}

enum SemanticNotificationKind: Equatable {
    case needsAttention, finished, updateInstalled, custom
    func encode(to w: inout WireWriter) {
        switch self {
        case .needsAttention: w.variant(0)
        case .finished: w.variant(1)
        case .updateInstalled: w.variant(2)
        case .custom: w.variant(3)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .needsAttention
        case 1: self = .finished
        case 2: self = .updateInstalled
        case 3: self = .custom
        case let v: throw EndpointWireError.badVariant("SemanticNotificationKind", v)
        }
    }
}

enum SemanticNotificationSound: Equatable {
    case done, request
    func encode(to w: inout WireWriter) {
        switch self { case .done: w.variant(0); case .request: w.variant(1) }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .done
        case 1: self = .request
        case let v: throw EndpointWireError.badVariant("SemanticNotificationSound", v)
        }
    }
}

enum ToastHerdrPosition: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
    func encode(to w: inout WireWriter) {
        switch self {
        case .topLeft: w.variant(0)
        case .topRight: w.variant(1)
        case .bottomLeft: w.variant(2)
        case .bottomRight: w.variant(3)
        }
    }
    init(from r: inout BincodeReader) throws {
        switch try r.readVarint() {
        case 0: self = .topLeft
        case 1: self = .topRight
        case 2: self = .bottomLeft
        case 3: self = .bottomRight
        case let v: throw EndpointWireError.badVariant("ToastHerdrPosition", v)
        }
    }
}

struct SemanticNotification: Equatable {
    var kind: SemanticNotificationKind
    var title: String
    var body: String?
    var sound: SemanticNotificationSound?
    var agent: String?
    var workspaceId: String?
    var tabId: String?
    var paneId: String?
    var position: ToastHerdrPosition?

    init(kind: SemanticNotificationKind, title: String, body: String?,
         sound: SemanticNotificationSound?, agent: String?,
         workspaceId: String?, tabId: String?, paneId: String?,
         position: ToastHerdrPosition?) {
        self.kind = kind; self.title = title; self.body = body; self.sound = sound
        self.agent = agent; self.workspaceId = workspaceId; self.tabId = tabId
        self.paneId = paneId; self.position = position
    }

    func encode(to w: inout WireWriter) {
        kind.encode(to: &w)
        w.string(title)
        if let body { w.bool(true); w.string(body) } else { w.bool(false) }
        if let sound { w.bool(true); sound.encode(to: &w) } else { w.bool(false) }
        if let agent { w.bool(true); w.string(agent) } else { w.bool(false) }
        if let workspaceId { w.bool(true); w.string(workspaceId) } else { w.bool(false) }
        if let tabId { w.bool(true); w.string(tabId) } else { w.bool(false) }
        if let paneId { w.bool(true); w.string(paneId) } else { w.bool(false) }
        if let position { w.bool(true); position.encode(to: &w) } else { w.bool(false) }
    }

    init(from r: inout BincodeReader) throws {
        kind = try SemanticNotificationKind(from: &r)
        title = try r.readString()
        body = try r.readBool() ? try r.readString() : nil
        sound = try r.readBool() ? try SemanticNotificationSound(from: &r) : nil
        agent = try r.readBool() ? try r.readString() : nil
        workspaceId = try r.readBool() ? try r.readString() : nil
        tabId = try r.readBool() ? try r.readString() : nil
        paneId = try r.readBool() ? try r.readString() : nil
        position = try r.readBool() ? try ToastHerdrPosition(from: &r) : nil
    }
}

// MARK: - Client messages (order = contract)

enum EndpointClientMessage {
    case terminalHello(version: UInt32, cols: UInt16, rows: UInt16,
                       cellWidthPx: UInt32, cellHeightPx: UInt32, pixelMouse: Bool)
    case input(data: [UInt8])
    case clipboardImage(target: ClientClipboardImageTarget,
                        extension: String, data: [UInt8])
    case resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32,
                cellHeightPx: UInt32, pixelMouse: Bool)
    case detach
    case attachTerminal(terminalId: String, takeover: Bool)
    case attachScroll(source: AttachScrollSource, direction: AttachScrollDirection,
                      lines: UInt16, column: UInt16?, row: UInt16?, modifiers: UInt8)
    case observeTerminal(target: String)
    case controlTerminal(target: String, takeover: Bool)
    case graphicsTransmissionResult(transferId: UInt64, imageId: UInt32, success: Bool)
    case graphicsTransmissionStarted(transferId: UInt64, imageId: UInt32)
    case clientShellHello(version: UInt32, cellWidthPx: UInt32, cellHeightPx: UInt32,
                          surfaceSize: ClientSurfaceSize, pixelMouse: Bool,
                          directGraphics: Bool, endpointKeybindings: Bool,
                          mouseCapture: Bool)
    case clientShellResize(cellWidthPx: UInt32, cellHeightPx: UInt32,
                           surfaceSize: ClientSurfaceSize, pixelMouse: Bool)
    case clientShellPaneInput(paneId: String, events: [ClientPaneInputEvent])
    case clientShellPopupInput(terminalId: String, events: [ClientPaneInputEvent])
    case clientShellEndpointRequest(bootId: String, request: String)
    case attachMouse(kind: ClientMouseKind, position: ClientMousePosition,
                     geometry: ClientMouseGeometry?, modifiers: UInt8, lines: UInt16)
    case clientShellHostTheme(update: ClientHostThemeUpdate)
    case clientShellFocus(focused: Bool)
    case clientShellMouseCapture(enabled: Bool)
    case endpointControl(kind: String, data: String)

    /// Length-prefixed (u32 LE) framed encoding.
    func encoded() -> [UInt8] {
        var w = WireWriter()
        write(to: &w)
        return BincodeFrame.frame(w.buf)
    }

    private func write(to w: inout WireWriter) {
        switch self {
        case let .terminalHello(version, cols, rows, cellWidthPx, cellHeightPx, pixelMouse):
            w.variant(0); w.u32(version); w.u16(cols); w.u16(rows)
            w.u32(cellWidthPx); w.u32(cellHeightPx); w.bool(pixelMouse)
        case .input(let data):
            w.variant(1); w.bytes(data)
        case let .clipboardImage(target, ext, data):
            w.variant(2); target.encode(to: &w); w.string(ext); w.bytes(data)
        case let .resize(cols, rows, cellWidthPx, cellHeightPx, pixelMouse):
            w.variant(3); w.u16(cols); w.u16(rows)
            w.u32(cellWidthPx); w.u32(cellHeightPx); w.bool(pixelMouse)
        case .detach:
            w.variant(4)
        case let .attachTerminal(terminalId, takeover):
            w.variant(5); w.string(terminalId); w.bool(takeover)
        case let .attachScroll(source, direction, lines, column, row, modifiers):
            w.variant(6)
            source.encode(to: &w); direction.encode(to: &w); w.u16(lines)
            if let column { w.bool(true); w.u16(column) } else { w.bool(false) }
            if let row { w.bool(true); w.u16(row) } else { w.bool(false) }
            w.u8(modifiers)
        case .observeTerminal(let target):
            w.variant(7); w.string(target)
        case let .controlTerminal(target, takeover):
            w.variant(8); w.string(target); w.bool(takeover)
        case let .graphicsTransmissionResult(transferId, imageId, success):
            w.variant(9); w.u64(transferId); w.u32(imageId); w.bool(success)
        case let .graphicsTransmissionStarted(transferId, imageId):
            w.variant(10); w.u64(transferId); w.u32(imageId)
        case let .clientShellHello(version, cellWidthPx, cellHeightPx,
                                  surfaceSize, pixelMouse, directGraphics,
                                  endpointKeybindings, mouseCapture):
            w.variant(11); w.u32(version); w.u32(cellWidthPx); w.u32(cellHeightPx)
            surfaceSize.encode(to: &w); w.bool(pixelMouse); w.bool(directGraphics)
            w.bool(endpointKeybindings); w.bool(mouseCapture)
        case let .clientShellResize(cellWidthPx, cellHeightPx, surfaceSize, pixelMouse):
            w.variant(12); w.u32(cellWidthPx); w.u32(cellHeightPx)
            surfaceSize.encode(to: &w); w.bool(pixelMouse)
        case let .clientShellPaneInput(paneId, events):
            w.variant(13); w.string(paneId)
            w.usize(events.count)
            for e in events { e.encode(to: &w) }
        case let .clientShellPopupInput(terminalId, events):
            w.variant(14); w.string(terminalId)
            w.usize(events.count)
            for e in events { e.encode(to: &w) }
        case let .clientShellEndpointRequest(bootId, request):
            w.variant(15); w.string(bootId); w.string(request)
        case let .attachMouse(kind, position, geometry, modifiers, lines):
            w.variant(16)
            kind.encode(to: &w); position.encode(to: &w)
            if let geometry { w.bool(true); geometry.encode(to: &w) } else { w.bool(false) }
            w.u8(modifiers); w.u16(lines)
        case .clientShellHostTheme(let update):
            w.variant(17); update.encode(to: &w)
        case .clientShellFocus(let focused):
            w.variant(18); w.bool(focused)
        case .clientShellMouseCapture(let enabled):
            w.variant(19); w.bool(enabled)
        case let .endpointControl(kind, data):
            w.variant(20); w.string(kind); w.string(data)
        }
    }

    /// Decode from a bare payload (no length prefix); trailing bytes reject.
    static func decode(payload: [UInt8]) throws -> EndpointClientMessage {
        var r = BincodeReader(payload)
        let message = try from(&r)
        guard r.remaining == 0 else { throw EndpointWireError.trailingBytes }
        return message
    }

    private static func from(_ r: inout BincodeReader) throws -> EndpointClientMessage {
        switch try r.readVarint() {
        case 0:
            return .terminalHello(version: try r.readU32(), cols: try r.readU16(),
                                  rows: try r.readU16(), cellWidthPx: try r.readU32(),
                                  cellHeightPx: try r.readU32(),
                                  pixelMouse: try r.readBool())
        case 1:
            return .input(data: try r.readBytes())
        case 2:
            return .clipboardImage(target: try ClientClipboardImageTarget(from: &r),
                                   extension: try r.readString(),
                                   data: try r.readBytes())
        case 3:
            return .resize(cols: try r.readU16(), rows: try r.readU16(),
                           cellWidthPx: try r.readU32(), cellHeightPx: try r.readU32(),
                           pixelMouse: try r.readBool())
        case 4:
            return .detach
        case 5:
            return .attachTerminal(terminalId: try r.readString(),
                                   takeover: try r.readBool())
        case 6:
            return .attachScroll(source: try AttachScrollSource(from: &r),
                                 direction: try AttachScrollDirection(from: &r),
                                 lines: try r.readU16(),
                                 column: try r.readBool() ? try r.readU16() : nil,
                                 row: try r.readBool() ? try r.readU16() : nil,
                                 modifiers: try r.readVarintU8())
        case 7:
            return .observeTerminal(target: try r.readString())
        case 8:
            return .controlTerminal(target: try r.readString(),
                                    takeover: try r.readBool())
        case 9:
            return .graphicsTransmissionResult(transferId: try r.readU64(),
                                               imageId: try r.readU32(),
                                               success: try r.readBool())
        case 10:
            return .graphicsTransmissionStarted(transferId: try r.readU64(),
                                                imageId: try r.readU32())
        case 11:
            return .clientShellHello(version: try r.readU32(),
                                     cellWidthPx: try r.readU32(),
                                     cellHeightPx: try r.readU32(),
                                     surfaceSize: try ClientSurfaceSize(from: &r),
                                     pixelMouse: try r.readBool(),
                                     directGraphics: try r.readBool(),
                                     endpointKeybindings: try r.readBool(),
                                     mouseCapture: try r.readBool())
        case 12:
            return .clientShellResize(cellWidthPx: try r.readU32(),
                                      cellHeightPx: try r.readU32(),
                                      surfaceSize: try ClientSurfaceSize(from: &r),
                                      pixelMouse: try r.readBool())
        case 13:
            let paneId = try r.readString()
            let n = try r.readBoundedLengthForEndpoint()
            var events: [ClientPaneInputEvent] = []
            for _ in 0..<n { events.append(try ClientPaneInputEvent(from: &r)) }
            return .clientShellPaneInput(paneId: paneId, events: events)
        case 14:
            let terminalId = try r.readString()
            let n = try r.readBoundedLengthForEndpoint()
            var events: [ClientPaneInputEvent] = []
            for _ in 0..<n { events.append(try ClientPaneInputEvent(from: &r)) }
            return .clientShellPopupInput(terminalId: terminalId, events: events)
        case 15:
            return .clientShellEndpointRequest(bootId: try r.readString(),
                                               request: try r.readString())
        case 16:
            return .attachMouse(kind: try ClientMouseKind(from: &r),
                                position: try ClientMousePosition(from: &r),
                                geometry: try r.readBool()
                                    ? try ClientMouseGeometry(from: &r) : nil,
                                modifiers: try r.readVarintU8(),
                                lines: try r.readU16())
        case 17:
            return .clientShellHostTheme(update: try ClientHostThemeUpdate(from: &r))
        case 18:
            return .clientShellFocus(focused: try r.readBool())
        case 19:
            return .clientShellMouseCapture(enabled: try r.readBool())
        case 20:
            return .endpointControl(kind: try r.readString(), data: try r.readString())
        case let v:
            throw EndpointWireError.badVariant("EndpointClientMessage", v)
        }
    }
}

// MARK: - Server messages (order = contract)

enum EndpointServerMessage {
    case welcome(version: UInt32, encoding: RenderEncoding, error: String?)
    case terminal(TerminalFrame)
    case graphics(bytes: [UInt8])
    case serverShutdown(reason: String?)
    case notify(kind: NotifyKind, message: String, body: String?)
    case clipboard(data: String)
    case windowTitle(title: String?)
    case reloadSoundConfig
    case mouseCapture(enabled: Bool, sgrPixels: Bool)
    case terminalBell(count: UInt16)
    case graphicsFile(path: String, expectedLen: UInt64, imageId: UInt32,
                      transferId: UInt64, leading: [UInt8], control: String,
                      surfaceAsset: SurfaceGraphicsAssetKey?)
    case graphicsTransmissionRetired(transferId: UInt64, imageId: UInt32)
    case clientShellSnapshot(ClientShellSnapshot)
    case paneSurface(PaneSurfaceFrame)
    case semanticNotification(SemanticNotification)
    case clientShellError(message: String)
    case directTerminalKeyboardProtocol(flags: UInt16, modifyOtherKeysLevel: UInt8)
    case clientShellKeyboardReportAll(enabled: Bool)
    case clientShellEndpointResponseChunk(bootId: String, requestId: String,
                                          finalChunk: Bool, data: [UInt8])
    case paneSurfacePatch(PaneSurfacePatch)
    case endpointControl(kind: String, data: String)

    /// Length-prefixed (u32 LE) framed encoding (mock server / tests).
    func encoded() -> [UInt8] {
        var w = WireWriter()
        write(to: &w)
        return BincodeFrame.frame(w.buf)
    }

    private func write(to w: inout WireWriter) {
        switch self {
        case let .welcome(version, encoding, error):
            w.variant(0); w.u32(version); encoding.encode(to: &w)
            if let error { w.bool(true); w.string(error) } else { w.bool(false) }
        case .terminal(let frame):
            w.variant(1); frame.encode(to: &w)
        case .graphics(let bytes):
            w.variant(2); w.bytes(bytes)
        case .serverShutdown(let reason):
            w.variant(3)
            if let reason { w.bool(true); w.string(reason) } else { w.bool(false) }
        case let .notify(kind, message, body):
            w.variant(4); kind.encode(to: &w); w.string(message)
            if let body { w.bool(true); w.string(body) } else { w.bool(false) }
        case .clipboard(let data):
            w.variant(5); w.string(data)
        case .windowTitle(let title):
            w.variant(6)
            if let title { w.bool(true); w.string(title) } else { w.bool(false) }
        case .reloadSoundConfig:
            w.variant(7)
        case let .mouseCapture(enabled, sgrPixels):
            w.variant(8); w.bool(enabled); w.bool(sgrPixels)
        case .terminalBell(let count):
            w.variant(9); w.u16(count)
        case let .graphicsFile(path, expectedLen, imageId, transferId,
                               leading, control, surfaceAsset):
            w.variant(10)
            w.string(path); w.u64(expectedLen); w.u32(imageId); w.u64(transferId)
            w.bytes(leading); w.string(control)
            if let surfaceAsset { w.bool(true); surfaceAsset.encode(to: &w) }
            else { w.bool(false) }
        case let .graphicsTransmissionRetired(transferId, imageId):
            w.variant(11); w.u64(transferId); w.u32(imageId)
        case .clientShellSnapshot(let snapshot):
            w.variant(12); snapshot.encode(to: &w)
        case .paneSurface(let frame):
            w.variant(13); frame.encode(to: &w)
        case .semanticNotification(let notification):
            w.variant(14); notification.encode(to: &w)
        case .clientShellError(let message):
            w.variant(15); w.string(message)
        case let .directTerminalKeyboardProtocol(flags, level):
            w.variant(16); w.u16(flags); w.u8(level)
        case .clientShellKeyboardReportAll(let enabled):
            w.variant(17); w.bool(enabled)
        case let .clientShellEndpointResponseChunk(bootId, requestId, finalChunk, data):
            w.variant(18); w.string(bootId); w.string(requestId)
            w.bool(finalChunk); w.bytes(data)
        case .paneSurfacePatch(let patch):
            w.variant(19); patch.encode(to: &w)
        case let .endpointControl(kind, data):
            w.variant(20); w.string(kind); w.string(data)
        }
    }

    /// Decode from a bare payload (no length prefix); trailing bytes reject.
    static func decode(payload: [UInt8]) throws -> EndpointServerMessage {
        var r = BincodeReader(payload)
        let message = try from(&r)
        guard r.remaining == 0 else { throw EndpointWireError.trailingBytes }
        return message
    }

    private static func from(_ r: inout BincodeReader) throws -> EndpointServerMessage {
        switch try r.readVarint() {
        case 0:
            return .welcome(version: try r.readU32(),
                            encoding: try RenderEncoding(from: &r),
                            error: try r.readBool() ? try r.readString() : nil)
        case 1:
            return .terminal(try TerminalFrame(from: &r))
        case 2:
            return .graphics(bytes: try r.readBytes())
        case 3:
            return .serverShutdown(reason: try r.readBool() ? try r.readString() : nil)
        case 4:
            return .notify(kind: try NotifyKind(from: &r),
                           message: try r.readString(),
                           body: try r.readBool() ? try r.readString() : nil)
        case 5:
            return .clipboard(data: try r.readString())
        case 6:
            return .windowTitle(title: try r.readBool() ? try r.readString() : nil)
        case 7:
            return .reloadSoundConfig
        case 8:
            return .mouseCapture(enabled: try r.readBool(),
                                 sgrPixels: try r.readBool())
        case 9:
            return .terminalBell(count: try r.readU16())
        case 10:
            return .graphicsFile(
                path: try r.readString(), expectedLen: try r.readU64(),
                imageId: try r.readU32(), transferId: try r.readU64(),
                leading: try r.readBytes(), control: try r.readString(),
                surfaceAsset: try r.readBool()
                    ? try SurfaceGraphicsAssetKey(from: &r) : nil)
        case 11:
            return .graphicsTransmissionRetired(transferId: try r.readU64(),
                                                imageId: try r.readU32())
        case 12:
            return .clientShellSnapshot(try ClientShellSnapshot(from: &r))
        case 13:
            return .paneSurface(try PaneSurfaceFrame(from: &r))
        case 14:
            return .semanticNotification(try SemanticNotification(from: &r))
        case 15:
            return .clientShellError(message: try r.readString())
        case 16:
            return .directTerminalKeyboardProtocol(flags: try r.readU16(),
                                                   modifyOtherKeysLevel: try r.readVarintU8())
        case 17:
            return .clientShellKeyboardReportAll(enabled: try r.readBool())
        case 18:
            return .clientShellEndpointResponseChunk(
                bootId: try r.readString(), requestId: try r.readString(),
                finalChunk: try r.readBool(), data: try r.readBytes())
        case 19:
            return .paneSurfacePatch(try PaneSurfacePatch(from: &r))
        case 20:
            return .endpointControl(kind: try r.readString(), data: try r.readString())
        case let v:
            throw EndpointWireError.badVariant("EndpointServerMessage", v)
        }
    }
}

// MARK: - BincodeReader conveniences (u8 via varint; bounded lengths)

extension BincodeReader {
    mutating func readVarintU8() throws -> UInt8 {
        UInt8(truncatingIfNeeded: try readVarint())
    }

    /// Collection length bounded by the 32 MiB inbound frame ceiling.
    mutating func readBoundedLengthForEndpoint() throws -> Int {
        let raw = try readVarint()
        guard raw <= 64 << 20 else { throw HerdrWireError.truncated }
        let n = Int(raw)
        guard n >= 0, remaining >= n else { throw HerdrWireError.truncated }
        return n
    }
}
