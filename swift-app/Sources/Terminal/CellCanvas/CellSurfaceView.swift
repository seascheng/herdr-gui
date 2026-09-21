import Foundation
import AppKit
import CoreText

// MARK: - pure layout logic (testable)

enum CellSurfaceLogic {
    /// Pane under a point, by inner rect only (borders are not panes).
    static func paneId(atX x: Double, atY y: Double, cellWidth: Double,
                       cellHeight: Double, panes: [PaneSurfacePane]) -> String? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        for pane in panes {
            let r = pane.innerRect
            guard x >= Double(r.x) * cellWidth,
                  x < Double(Int(r.x) + Int(r.width)) * cellWidth,
                  y >= Double(r.y) * cellHeight,
                  y < Double(Int(r.y) + Int(r.height)) * cellHeight
            else { continue }
            return pane.paneId
        }
        return nil
    }

    static func cellAt(x: Double, y: Double, cellWidth: Double,
                       cellHeight: Double) -> (col: Int, row: Int)? {
        guard x >= 0, y >= 0, cellWidth > 0, cellHeight > 0 else { return nil }
        return (Int(x / cellWidth), Int(y / cellHeight))
    }

    /// Like cellAt, but clamps into the given bounds: selections that start
    /// or end outside the grid stay valid at its edges.
    static func clampedCell(x: Double, y: Double, cellWidth: Double,
                            cellHeight: Double, cols: Int, rows: Int)
        -> (col: Int, row: Int) {
        (min(max(Int(max(x, 0) / max(cellWidth, 1)), 0), max(cols - 1, 0)),
         min(max(Int(max(y, 0) / max(cellHeight, 1)), 0), max(rows - 1, 0)))
    }

    /// Word bounds around a cell: runs of non-space symbols on one row.
    static func wordStart(cells: [CellData], width: Int, col: Int, row: Int)
        -> (col: Int, row: Int) {
        guard width > 0, row * width + col < cells.count else { return (col, row) }
        var c = col
        while c > 0 {
            let cell = cells[row * width + c - 1]
            if cell.skip || cell.symbol.isEmpty || cell.symbol == " " { break }
            c -= 1
        }
        return (c, row)
    }

    static func wordEnd(cells: [CellData], width: Int, col: Int, row: Int)
        -> (col: Int, row: Int) {
        guard width > 0, row * width + col < cells.count else { return (col, row) }
        var c = col
        while c < width - 1 {
            let cell = cells[row * width + c + 1]
            if cell.skip || cell.symbol.isEmpty || cell.symbol == " " { break }
            c += 1
        }
        return (c, row)
    }

    /// Streaming (character-flow) selection spans between two cells, within
    /// column bounds `x0...x1`: partial first line, full middle lines,
    /// partial last line — terminal-standard selection, not a block.
    static func rowSpans(anchor: (col: Int, row: Int), head: (col: Int, row: Int),
                         x0: Int, x1: Int) -> [(row: Int, from: Int, to: Int)] {
        let x0 = max(x0, 0)
        let x1 = max(x1, x0)
        let start = anchor.row <= head.row ? anchor : head
        let end = anchor.row <= head.row ? head : anchor
        if start.row == end.row {
            return [(start.row, min(start.col, end.col), max(start.col, end.col))]
        }
        var spans: [(row: Int, from: Int, to: Int)] = []
        spans.append((start.row, max(start.col, x0), x1))
        for row in (start.row + 1)..<end.row {
            spans.append((row, x0, x1))
        }
        spans.append((end.row, x0, min(end.col, x1)))
        return spans
    }

    /// Centered popup origin, floored, saturating at zero.
    static func popupOrigin(mainCols: Int, mainRows: Int, popupCols: Int,
                            popupRows: Int, cellWidth: Double, cellHeight: Double)
        -> (x: Double, y: Double) {
        let x = (Double(mainCols - popupCols) * cellWidth / 2).rounded(.down)
        let y = Double(mainRows - popupRows) * cellHeight / 2
        return (max(x, 0), max(y, 0))
    }

    /// Split divider under a point (hit rects are in surface cells).
    static func splitHit(atX x: Double, atY y: Double, cellWidth: Double,
                         cellHeight: Double,
                         splits: [PaneSurfaceSplit]) -> PaneSurfaceSplit? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let col = x / cellWidth
        let row = y / cellHeight
        return splits.first { split in
            let r = split.hitRect
            return col >= Double(r.x)
                && col < Double(Int(r.x) + Int(r.width))
                && row >= Double(r.y)
                && row < Double(Int(r.y) + Int(r.height))
        }
    }

    /// Divider drag ratio: pointer position along the split's area minus
    /// the initial grab offset, clamped to 0...1 (herdr TUI mouse.rs).
    static func splitRatio(pointerCells: Double, areaOrigin: Double,
                           areaLength: Double, grabOffset: Double) -> Double {
        guard areaLength > 0 else { return 0.5 }
        let ratio = (pointerCells - areaOrigin - grabOffset) / areaLength
        return min(max(ratio, 0), 1)
    }

    /// First/last cell with visible content inside a span; nil when the
    /// whole span is blank. Selection highlight and copy snap to this, so
    /// dragging over empty space selects nothing visible.
    static func spanContentBounds(cells: [CellData], width: Int,
                                  row: Int, from: Int, to: Int)
        -> (from: Int, to: Int)? {
        guard width > 0, row >= 0, to >= from else { return nil }
        let lo = max(from, 0)
        let hi = min(to, width - 1)
        guard hi >= lo, row * width + hi < cells.count else { return nil }
        var first: Int? = nil
        var last: Int? = nil
        for col in lo...hi {
            let cell = cells[row * width + col]
            if !cell.skip, !cell.symbol.isEmpty, cell.symbol != " " {
                if first == nil { first = col }
                last = col
            }
        }
        guard let first, let last else { return nil }
        return (first, last)
    }

    /// DECSCUSR cursor shapes: 3|4 bottom underline bar, 5|6 left bar,
    /// everything else a full block.
    static func cursorRect(x: UInt16, y: UInt16, shape: UInt8,
                           cellWidth: Double, cellHeight: Double)
        -> (x: Double, y: Double, w: Double, h: Double) {
        let px = Double(x) * cellWidth
        let py = Double(y) * cellHeight
        switch shape {
        case 3, 4:
            return (px, py + cellHeight - 2, cellWidth, 2)
        case 5, 6:
            return (px, py, 2, cellHeight)
        default:
            return (px, py, cellWidth, cellHeight)
        }
    }
}

// MARK: - CoreText cell canvas
//
// Painting model: one CTLine per ROW (not per glyph). Glyph advances are
// pinned to the cell grid with per-glyph kern; rows whose cells did not
// change reuse the cached CTLine and are not marked dirty.

final class CellSurfaceView: NSView, NSTextInputClient {
    var theme = CellTheme.defaults

    // Main-thread lifecycle callbacks.
    var onPaneInput: ((String, [ClientPaneInputEvent]) -> Void)?
    var onPopupInput: ((String, [ClientPaneInputEvent]) -> Void)?
    var onResize: ((ClientSurfaceSize, UInt32, UInt32) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onFocusedTitle: ((String?) -> Void)?
    /// Click-to-focus: endpoint focus is a `pane.focus` request, not a
    /// synthesized TUI click (herdr-gpui semantics).
    var onFocusPane: ((String) -> Void)?
    /// Generic request lane (split create/navigate, divider drag resize).
    var onRequest: ((String, [String: Any]) -> Void)?
    /// Focused tab id from the latest snapshot (divider resize targets it).
    var contextTabId: String?

    private(set) var surface: PaneSurfaceFrame?
    private var font: NSFont
    private var boldFont: NSFont
    private var italicFont: NSFont
    private(set) var cellWidth: Double = 8
    private(set) var cellHeight: Double = 17
    /// Ghostty `cursor-style` override (nil = follow the server's shape).
    var cursorShapeOverride: UInt8?
    /// Ghostty `cursor-style-blink`: steady-off half-phase toggle.
    var cursorBlinks = false
    private var blinkPhase = true
    private var blinkTimer: Timer?

    /// Shaped lines keyed by row CONTENT (not index): scrolling moves row
    /// content between indices, so content addressing keeps the hits.
    private var rowLines: [[CellData]: CTLine] = [:]
    /// Previous frame's rows, for dirty-row detection.
    private var previousRows: [[CellData]] = []
    /// Natural advance per symbol (for the kern that pins glyphs to cells).
    private var symbolAdvances: [String: Double] = [:]

    private var wheel = WheelAccumulator()
    private var lastReportedSize = ClientSurfaceSize(cols: 0, rows: 0)
    private var resizeDebounce: DispatchWorkItem?
    private var markedText: String?
    private var hoverLinkURL: String?

    // Streaming selection, constrained to the pane where it started.
    private var selectionAnchor: (col: Int, row: Int)?
    private var selectionHead: (col: Int, row: Int)?
    private var selectionBounds: (x0: Int, x1: Int, y0: Int, y1: Int)?
    private var isDraggingSelection = false
    private var mouseDownPane: String?
    /// Active divider drag: split path + geometry + grab offset (TUI
    /// semantics: ratio requests throttled to 33 ms).
    private var dragSplit: (path: [Bool], area: SurfaceRect,
                            horizontal: Bool, grabOffset: Double,
                            lastSent: Date)?

    override var acceptsFirstResponder: Bool { true }

    /// Top-left origin: every grid computation (rows, hit-testing, mouse
    /// coordinates) is written in terminal top-down space.
    override var isFlipped: Bool { true }

    init() {
        let size = UserDefaults.standard.double(forKey: "cellFontSize")
        let point = size >= 8 && size <= 48 ? size : 14.0
        font = NSFont.monospacedSystemFont(ofSize: point, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: point, weight: .bold)
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        super.init(frame: .zero)
        wantsLayer = true
        measureCells()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// herdr-gpui's metric recipe: cell height = font size × 20/14
    /// (1.43×), deliberately NOT the font's own ascent+descent — CJK
    /// families like "Maple Mono NF CN" carry inflated metrics that would
    /// blow up line spacing. The font is vertically centered in the cell.
    private func measureCells() {
        let size = Double(font.pointSize)
        cellHeight = (size * 20.0 / 14.0).rounded()
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "M", attributes: attrs))
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        cellWidth = max(width.rounded(.up), 1)
        invalidateStyle()
        scheduleResize()
    }

    /// Baseline offset that centers the glyph band inside the cell
    /// (Ghostty's "font centered vertically" behavior).
    private var baselineOffsetCache: (font: NSObject, offset: Double)?
    private func centeredBaseline() -> Double {
        let ctFont = font as CTFont
        let ascent = Double(CTFontGetAscent(ctFont))
        let descent = Double(CTFontGetDescent(ctFont))
        let natural = ascent + descent
        let centering = max(cellHeight - natural, 0) / 2
        return (centering + ascent).rounded(.down)
    }

    /// Style-level invalidation (theme colors, font): shaped rows carry
    /// baked-in colors, so they must be rebuilt.
    func invalidateStyle() {
        rowLines.removeAll()
        previousRows = []
        symbolAdvances.removeAll()
        needsDisplay = true
    }

    func setFontSize(_ point: Double) {
        applyFont(family: nil, size: point, adjustCellHeight: 0)
    }

    /// Font from the Ghostty config: family (e.g. "Maple Mono NF CN") and
    /// size. Falls back to the system monospace when the family cannot be
    /// resolved. adjust-cell-height is intentionally not applied (the
    /// fixed 20/14 line-height ratio replaces it).
    func applyFont(family: String?, size: CGFloat, adjustCellHeight: CGFloat) {
        var base: NSFont
        if let family {
            let matched = CTFontCreateWithName(family as CFString, size, nil) as NSFont
            // Unresolvable names come back as the last-resort font; only
            // accept a real family match.
            let familyName = (matched.familyName ?? "").lowercased()
            if !familyName.isEmpty
                && familyName != "lastresort"
                && (familyName.contains(family.lowercased().prefix(6))
                    || family.lowercased().contains(familyName.prefix(6))) {
                base = matched
            } else {
                base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
        } else {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        font = base
        boldFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        italicFont = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        measureCells()
    }

    // MARK: Surface updates (main thread)

    func update(surface newSurface: PaneSurfaceFrame) {
        guard newSurface.surfaceRevision != surface?.surfaceRevision
            || newSurface.projectionRevision != surface?.projectionRevision
            || newSurface.bootId != surface?.bootId
        else { return }
        let old = surface
        surface = newSurface
        let frame = newSurface.frame
        let width = Int(frame.width)

        if old == nil || old!.frame.width != frame.width
            || old!.frame.height != frame.height || old!.bootId != newSurface.bootId {
            previousRows = []
            needsDisplay = true
        } else if previousRows.count == Int(frame.height) {
            // Row-level dirty tracking: only changed rows repaint.
            for row in 0..<Int(frame.height) {
                let slice = Array(frame.cells[(row * width)..<((row + 1) * width)])
                if slice == previousRows[row] { continue }
                setNeedsDisplay(rowRect(row))
            }
        } else {
            needsDisplay = true
        }
        previousRows = (0..<Int(frame.height)).map {
            Array(frame.cells[($0 * width)..<(($0 + 1) * width)])
        }
        if rowLines.count > 600 { rowLines.removeAll(keepingCapacity: true) }
        scheduleResize()
        updateBlinkTimer()
        if ProcessInfo.processInfo.environment["HERDR_DUMP_CELLS"] == "1" {
            dumpCells()
        }
    }

    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: Double(row) * cellHeight, width: bounds.width,
               height: cellHeight)
    }

    var focusedPaneId: String? {
        surface?.panes.first(where: \.focused)?.paneId
            ?? surface?.panes.first?.paneId
    }

    /// Self-capture of the painted canvas (same-process, no TCC): the
    /// HERDR_DUMP_CELLS smoke harness reads the PNG back. Retries until
    /// the view has been laid out.
    private var dumpAttempts = 0
    private func dumpCells() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard self.bounds.width > 10, self.surface != nil else {
                self.dumpAttempts += 1
                if self.dumpAttempts < 20 { self.dumpCells() }
                return
            }
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(self.bounds.width),
                pixelsHigh: Int(self.bounds.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            let bitmap = NSGraphicsContext(bitmapImageRep: image)
            NSGraphicsContext.current = bitmap
            // Emulate a flipped view: bitmap contexts are y-up, while the
            // draw() math assumes the view's top-left origin.
            bitmap?.cgContext.translateBy(x: 0, y: CGFloat(image.pixelsHigh))
            bitmap?.cgContext.scaleBy(x: 1, y: -1)
            self.draw(.infinite)
            NSGraphicsContext.restoreGraphicsState()
            if let data = image.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/herdr-cells.png"))
            }
        }
    }

    // MARK: Resize

    private func scheduleResize() {
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let size = CellInputMapper.viewport(
                width: Double(self.bounds.width),
                height: Double(self.bounds.height),
                cellWidth: self.cellWidth, cellHeight: self.cellHeight)
            guard size != self.lastReportedSize else { return }
            self.lastReportedSize = size
            self.onResize?(size, UInt32(self.cellWidth), UInt32(self.cellHeight))
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func layout() {
        super.layout()
        scheduleResize()
    }

    // MARK: Cursor blink

    /// Starts/stops the blink timer for the current config + focus.
    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkPhase = true
        guard cursorBlinks, let cursor = surface?.frame.cursor,
              cursor.visible, window?.isKeyWindow == true,
              (window?.firstResponder as? NSView) === self
        else {
            setNeedsDisplay(cursorDrawRect())
            return
        }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkPhase.toggle()
            self.setNeedsDisplay(self.cursorDrawRect())
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func cursorDrawRect() -> NSRect {
        guard let cursor = surface?.frame.cursor, cursor.visible,
              cursor.x < surface!.frame.width, cursor.y < surface!.frame.height
        else { return .zero }
        let rect = CellSurfaceLogic.cursorRect(
            x: cursor.x, y: cursor.y, shape: cursorShapeOverride ?? cursor.shape,
            cellWidth: cellWidth, cellHeight: cellHeight)
        return NSRect(x: rect.x, y: rect.y, width: rect.w + 1, height: rect.h + 1)
    }

    /// Typing resets the blink to the visible half-phase.
    func resetCursorBlink() {
        blinkPhase = true
        setNeedsDisplay(cursorDrawRect())
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { updateBlinkTimer() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { updateBlinkTimer() }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBlinkTimer()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let surface, surface.frame.width > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let frame = surface.frame
        let width = Int(frame.width)

        if dirtyRect == .infinite {
            fill(context, CGRect(x: 0, y: 0, width: bounds.width,
                                 height: Double(frame.height) * cellHeight),
                 color: theme.background, alpha: 1)
        }

        for row in 0..<Int(frame.height) {
            let rect = rowRect(row)
            guard dirtyRect == .infinite || rect.intersects(dirtyRect) else {
                continue
            }
            drawRow(row, cells: frame.cells, width: width,
                    context: context, dirty: dirtyRect == .infinite)
        }

        // Selection overlay (streaming spans, snapped to actual content).
        if let anchor = selectionAnchor, let head = selectionHead,
           let bounds = selectionBounds {
            let spans = CellSurfaceLogic.rowSpans(anchor: anchor, head: head,
                                                  x0: bounds.x0, x1: bounds.x1)
            for span in spans {
                guard let content = CellSurfaceLogic.spanContentBounds(
                        cells: frame.cells, width: width,
                        row: span.row, from: span.from, to: span.to)
                else { continue }  // blank rows highlight nothing
                let rect = CGRect(
                    x: Double(content.from) * cellWidth,
                    y: Double(span.row) * cellHeight,
                    width: Double(content.to - content.from + 1) * cellWidth,
                    height: cellHeight)
                fill(context, rect, color: 0x999999, alpha: 0.35)
            }
        }
        if let cursor = frame.cursor, cursor.visible,
           cursor.x < frame.width, cursor.y < frame.height {
            let shape = cursorShapeOverride ?? cursor.shape
            let rect = CellSurfaceLogic.cursorRect(
                x: cursor.x, y: cursor.y, shape: shape,
                cellWidth: cellWidth, cellHeight: cellHeight)
            fill(context, CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h),
                 color: theme.cursor, alpha: 0.5)
        }

        // Popup overlay: centered, after everything.
        if let popup = surface.popup {
            let origin = CellSurfaceLogic.popupOrigin(
                mainCols: width, mainRows: Int(frame.height),
                popupCols: Int(popup.frame.width),
                popupRows: Int(popup.frame.height),
                cellWidth: cellWidth, cellHeight: cellHeight)
            let box = CGRect(x: origin.x, y: origin.y,
                             width: Double(popup.frame.width) * cellWidth,
                             height: Double(popup.frame.height) * cellHeight)
            fill(context, box, color: theme.background, alpha: 1)
            stroke(context, box, color: theme.foreground, alpha: 0.6)
            for row in 0..<Int(popup.frame.height) {
                drawRowCells(popup.frame.cells, width: Int(popup.frame.width),
                             row: row, originX: origin.x,
                             context: context, cacheKey: "popup\(row)")
            }
        }
    }

    /// One row: background spans + one CTLine for all glyphs (grid-pinned
    private func drawRow(_ row: Int, cells: [CellData], width: Int,
                         context: CGContext, dirty: Bool) {
        let slice = Array(cells[(row * width)..<((row + 1) * width)])
        if dirty {
            drawBackgroundSpans(slice, row: row, context: context)
        }
        let line: CTLine
        if let cached = rowLines[slice] {
            line = cached
        } else {
            line = buildRowLine(slice)
            rowLines[slice] = line
        }
        let ascent = fontBaselineOffset()
        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: 0, y: CGFloat(Double(row) * cellHeight) + ascent)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()

        // Decorations at exact cell-grid coordinates.
        for (col, cell) in slice.enumerated() {
            let colors = theme.cellColors(cell)
            if cell.modifier & CellTheme.underline != 0 {
                fill(context,
                     CGRect(x: Double(col) * cellWidth,
                            y: Double(row) * cellHeight + cellHeight - 2,
                            width: cellWidth, height: 1),
                     color: colors.fg, alpha: 1)
            }
            if cell.modifier & CellTheme.strikethrough != 0 {
                fill(context,
                     CGRect(x: Double(col) * cellWidth,
                            y: Double(row) * cellHeight + cellHeight / 2,
                            width: cellWidth, height: 1),
                     color: colors.fg, alpha: 1)
            }
            if cell.hyperlink != nil {
                fill(context,
                     CGRect(x: Double(col) * cellWidth,
                            y: Double(row) * cellHeight + cellHeight - 1,
                            width: cellWidth, height: 1),
                     color: colors.fg, alpha: 1)
            }
        }
    }

    /// Popup rows draw with their own cache namespace and no dirty tracking.
    private func drawRowCells(_ cells: [CellData], width: Int, row: Int,
                              originX: Double, context: CGContext,
                              cacheKey: String) {
        let slice = Array(cells[(row * width)..<((row + 1) * width)])
        let ascent = fontBaselineOffset()
        let line = buildRowLine(slice)
        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(
            x: CGFloat(originX),
            y: CGFloat(Double(row) * cellHeight) + ascent)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
        _ = cacheKey
    }

    private func drawBackgroundSpans(_ rowCells: [CellData], row: Int,
                                     context: CGContext) {
        var start = 0
        var bg = theme.cellColors(rowCells[0]).bg
        var index = 1
        while index <= rowCells.count {
            let nextBg = index < rowCells.count
                ? theme.cellColors(rowCells[index]).bg : bg
            if index == rowCells.count || nextBg != bg {
                fill(context,
                     CGRect(x: Double(start) * cellWidth,
                            y: Double(row) * cellHeight,
                            width: Double(index - start) * cellWidth,
                            height: cellHeight),
                     color: bg, alpha: 1)
                if index < rowCells.count {
                    start = index
                    bg = nextBg
                }
            }
            index += 1
        }
    }

    /// Builds one CTLine for a row. Per-glyph kern = occupiedColumns *
    /// cellWidth − naturalAdvance pins every glyph to its cell; wide
    /// graphemes (followed by `skip` continuation cells) span their columns.
    private func buildRowLine(_ rowCells: [CellData]) -> CTLine {
        let attributed = NSMutableAttributedString()
        var col = 0
        while col < rowCells.count {
            let cell = rowCells[col]
            var columns = 1
            while col + columns < rowCells.count, rowCells[col + columns].skip {
                columns += 1
            }
            let symbol = cell.symbol.isEmpty ? " " : cell.symbol
            let advance = symbolAdvance(symbol)
            var kern = cellWidth - advance
            if columns > 1 {
                kern = Double(columns) * cellWidth - advance
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: rowFont(cell),
                .foregroundColor: NSColor(rgb: theme.cellColors(cell).fg),
            ]
            if abs(kern) > 0.01 {
                attributes[.kern] = NSNumber(value: kern)
            }
            attributed.append(NSAttributedString(string: symbol, attributes: attributes))
            col += columns
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    private func rowFont(_ cell: CellData) -> NSFont {
        if cell.modifier & CellTheme.bold != 0 { return boldFont }
        if cell.modifier & CellTheme.italic != 0 { return italicFont }
        return font
    }

    /// Natural typographic advance of a single symbol (cached).
    private func symbolAdvance(_ symbol: String) -> Double {
        if let cached = symbolAdvances[symbol] { return cached }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: symbol, attributes: attrs))
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        symbolAdvances[symbol] = width
        return width
    }

    private func fill(_ context: CGContext, _ rect: CGRect, color: UInt32,
                      alpha: CGFloat) {
        context.setFillColor(
            red: CGFloat((color >> 16) & 255) / 255,
            green: CGFloat((color >> 8) & 255) / 255,
            blue: CGFloat(color & 255) / 255,
            alpha: alpha)
        context.fill(rect)
    }

    private func stroke(_ context: CGContext, _ rect: CGRect, color: UInt32,
                        alpha: CGFloat) {
        context.setStrokeColor(
            red: CGFloat((color >> 16) & 255) / 255,
            green: CGFloat((color >> 8) & 255) / 255,
            blue: CGFloat(color & 255) / 255,
            alpha: alpha)
        context.stroke(rect)
    }

    private func fontBaselineOffset() -> Double {
        centeredBaseline()
    }

    // MARK: Selection (streaming, pane-constrained)

    func copy(_ sender: Any?) {
        guard let surface, let anchor = selectionAnchor, let head = selectionHead
        else { return }
        let frame = surface.popup?.frame ?? surface.frame
        guard let bounds = selectionBounds else { return }
        let spans = CellSurfaceLogic.rowSpans(anchor: anchor, head: head,
                                              x0: bounds.x0, x1: bounds.x1)
        let width = Int(frame.width)
        var lines: [String] = []
        for span in spans where span.row < Int(frame.height) {
            // Snap to content: leading/trailing blanks are layout, not text.
            guard let content = CellSurfaceLogic.spanContentBounds(
                    cells: frame.cells, width: width,
                    row: span.row, from: span.from, to: span.to)
            else {
                lines.append("")  // interior blank rows keep line structure
                continue
            }
            var line = ""
            for col in content.from...min(content.to, width - 1)
            where span.row * width + col < frame.cells.count {
                let cell = frame.cells[span.row * width + col]
                if !cell.skip { line += cell.symbol }
            }
            lines.append(line)
        }
        while lines.last == "" { lines.removeLast() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Input — keyboard

    override func keyDown(with event: NSEvent) {
        // While an IME composition is active the input method owns every
        // key: Enter confirms, Esc cancels, arrows navigate candidates.
        // Leaking Enter to the terminal here confirms nothing upstream.
        if markedText != nil {
            if Self.imeDebug, event.keyCode == 36 {
                epDbg("enter during composition -> inputContext")
            }
            interpretKeyEvents([event])
            return
        }
        // Printable text and IME go through interpretKeyEvents → insertText
        // → TextCommit; non-printables map to semantic Key events.
        let chars = event.charactersIgnoringModifiers ?? ""
        if let key = CellInputMapper.keyEvent(keyCode: event.keyCode, chars: chars,
                                              modifierFlags: event.modifierFlags,
                                              isRepeat: event.isARepeat) {
            resetCursorBlink()
            send(key)
            return
        }
        interpretKeyEvents([event])
    }

    private func send(_ event: ClientPaneInputEvent) {
        guard let surface else { return }
        if let popup = surface.popup {
            onPopupInput?(popup.terminalId, [event])
        } else if let paneId = focusedPaneId {
            onPaneInput?(paneId, [event])
        }
    }

    // MARK: NSTextInputClient (IME → TextCommit)

    private static let imeDebug =
        ProcessInfo.processInfo.environment["HERDR_ENDPOINT_DEBUG"] == "1"

    private static func imeString(_ any: Any) -> String? {
        if let s = any as? String { return s }
        if let a = any as? NSAttributedString { return a.string }
        return nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        if Self.imeDebug {
            epDbg("insertText \(String(describing: string).prefix(40))")
        }
        markedText = nil
        resetCursorBlink()
        guard let text = Self.imeString(string), !text.isEmpty else { return }
        send(.textCommit(text))
    }

    func doCommandBy(_ selector: Selector) {
        // No composition: interpret the standard editing commands the
        // input context emits as semantic key events.
        switch selector {
        case #selector(insertNewline(_:)):
            send(.key(code: .enter, modifiers: 0, kind: .press, repeatCount: 1,
                      shiftedCodepoint: nil, generatedText: nil,
                      tracksRelease: false, physicalKeyId: nil, windowsRecord: nil))
        case #selector(cancelOperation(_:)):
            send(.key(code: .esc, modifiers: 0, kind: .press, repeatCount: 1,
                      shiftedCodepoint: nil, generatedText: nil,
                      tracksRelease: false, physicalKeyId: nil, windowsRecord: nil))
        case #selector(deleteBackward(_:)):
            send(.key(code: .backspace, modifiers: 0, kind: .press, repeatCount: 1,
                      shiftedCodepoint: nil, generatedText: nil,
                      tracksRelease: false, physicalKeyId: nil, windowsRecord: nil))
        case #selector(moveLeft(_:)):
            send(.key(code: .left, modifiers: 0, kind: .press, repeatCount: 1,
                      shiftedCodepoint: nil, generatedText: nil,
                      tracksRelease: false, physicalKeyId: nil, windowsRecord: nil))
        case #selector(moveRight(_:)):
            send(.key(code: .right, modifiers: 0, kind: .press, repeatCount: 1,
                      shiftedCodepoint: nil, generatedText: nil,
                      tracksRelease: false, physicalKeyId: nil, windowsRecord: nil))
        case #selector(moveUp(_:)):
            send(.key(code: .up, modifiers: 0, kind: .press, repeatCount: 1,
                      shiftedCodepoint: nil, generatedText: nil,
                      tracksRelease: false, physicalKeyId: nil, windowsRecord: nil))
        case #selector(moveDown(_:)):
            send(.key(code: .down, modifiers: 0, kind: .press, repeatCount: 1,
                      shiftedCodepoint: nil, generatedText: nil,
                      tracksRelease: false, physicalKeyId: nil, windowsRecord: nil))
        default:
            break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange,
                       replacementRange: NSRange) {
        markedText = Self.imeString(string)
        if Self.imeDebug {
            epDbg("setMarkedText [\(markedText ?? "nil")]")
        }
        needsDisplay = true
    }

    func unmarkText() { markedText = nil; needsDisplay = true }
    func hasMarkedText() -> Bool { markedText != nil }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }
    func markedRange() -> NSRange {
        markedText.map { NSRange(location: 0, length: ($0 as NSString).length) }
            ?? NSRange(location: 0, length: 0)
    }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.foregroundColor, .font]
    }
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        let frame = surface.popup?.frame ?? surface.frame
        let rect: (x: Double, y: Double, w: Double, h: Double)
        if let cursor = frame.cursor {
            rect = CellSurfaceLogic.cursorRect(x: cursor.x, y: cursor.y, shape: 0,
                                               cellWidth: cellWidth,
                                               cellHeight: cellHeight)
        } else {
            rect = (0, 0, cellWidth, cellHeight)
        }
        var viewRect = NSRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        viewRect = convert(viewRect, to: nil)
        return window?.convertToScreen(viewRect)
            ?? NSRect(x: 0, y: 0, width: cellWidth, height: cellHeight)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Input — mouse

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Cmd-click opens hyperlinks instead of touching the pane.
        if event.modifierFlags.contains(.command),
           let urlString = link(at: point),
           let url = URL(string: urlString) {
            onOpenURL?(url)
            return
        }
        // Divider drag: hit rects first, before pane hit-testing.
        if surface.popup == nil,
           let split = CellSurfaceLogic.splitHit(
               atX: Double(point.x), atY: Double(point.y),
               cellWidth: cellWidth, cellHeight: cellHeight,
               splits: surface.splits) {
            let horizontal = split.direction == .horizontal
            let pointerCells = horizontal
                ? Double(point.x) / cellWidth : Double(point.y) / cellHeight
            let divider = horizontal
                ? Double(split.area.x + split.pos)
                : Double(split.area.y + split.pos)
            dragSplit = (split.path, split.area, horizontal,
                         pointerCells - divider, .distantPast)
            selectionAnchor = nil
            selectionHead = nil
            return
        }
        // Selection lives inside one pane's inner rect (borders excluded).
        let paneId = CellSurfaceLogic.paneId(atX: Double(point.x),
                                             atY: Double(point.y),
                                             cellWidth: cellWidth,
                                             cellHeight: cellHeight,
                                             panes: surface.panes)
        let inner = paneId.flatMap { id in
            surface.panes.first { $0.paneId == id }?.innerRect
        }
        if let inner {
            let x0 = Int(inner.x), x1 = Int(inner.x) + Int(inner.width) - 1
            let y0 = Int(inner.y), y1 = Int(inner.y) + Int(inner.height) - 1
            selectionBounds = (x0, x1, y0, y1)
            // Anchor/head are ABSOLUTE surface cell coordinates, clamped
            // into the pane's inner rect.
            let cell = CellSurfaceLogic.clampedCell(
                x: Double(point.x), y: Double(point.y),
                cellWidth: cellWidth, cellHeight: cellHeight,
                cols: x1 + 1, rows: y1 + 1)
            let anchor = (col: min(max(cell.col, x0), x1),
                          row: min(max(cell.row, y0), y1))
            if event.clickCount == 2 {
                let popupFrame = surface.popup?.frame
                let cells = popupFrame?.cells ?? surface.frame.cells
                let width = popupFrame.map { Int($0.width) } ?? Int(surface.frame.width)
                let start = CellSurfaceLogic.wordStart(cells: cells, width: width,
                                                       col: anchor.col, row: anchor.row)
                let end = CellSurfaceLogic.wordEnd(cells: cells, width: width,
                                                   col: anchor.col, row: anchor.row)
                selectionAnchor = (start.col, anchor.row)
                selectionHead = (end.col, anchor.row)
                isDraggingSelection = false
            } else {
                selectionAnchor = anchor
                selectionHead = anchor
                isDraggingSelection = true
            }
        } else {
            selectionAnchor = nil
            selectionHead = nil
            selectionBounds = nil
        }
        mouseDownPane = paneId
        // Clicking a pane focuses it through the API (endpoint semantics:
        // focus is a request, not a synthesized TUI click).
        if let paneId = mouseDownPane {
            onFocusPane?(paneId)
            if paneReportsMouse(paneId) {
                sendMouse(event, point: point, isDown: true, isDrag: false)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let drag = dragSplit {
            let pointerCells = drag.horizontal
                ? Double(point.x) / cellWidth : Double(point.y) / cellHeight
            let ratio = CellSurfaceLogic.splitRatio(
                pointerCells: pointerCells,
                areaOrigin: drag.horizontal ? Double(drag.area.x) : Double(drag.area.y),
                areaLength: Double(drag.horizontal ? drag.area.width : drag.area.height),
                grabOffset: drag.grabOffset)
            let now = Date()
            guard now.timeIntervalSince(drag.lastSent) >= 0.033 else { return }
            dragSplit?.lastSent = now
            var params: [String: Any] = ["path": drag.path, "ratio": ratio]
            if let tabId = contextTabId { params["tab_id"] = tabId }
            onRequest?("layout.set_split_ratio", params)
            return
        }
        if isDraggingSelection, let bounds = selectionBounds {
            let cell = CellSurfaceLogic.clampedCell(
                x: Double(point.x), y: Double(point.y),
                cellWidth: cellWidth, cellHeight: cellHeight,
                cols: bounds.x1 + 1, rows: bounds.y1 + 1)
            selectionHead = (min(max(cell.col, bounds.x0), bounds.x1),
                             min(max(cell.row, bounds.y0), bounds.y1))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragSplit = nil
        // A zero-extent single click is focus/select-none, not a selection.
        if event.clickCount < 2,
           let anchor = selectionAnchor, let head = selectionHead,
           anchor.col == head.col, anchor.row == head.row {
            selectionAnchor = nil
            selectionHead = nil
        }
        isDraggingSelection = false
        if let paneId = mouseDownPane, paneReportsMouse(paneId) {
            sendMouse(event, point: point, isDown: false, isDrag: false)
        }
        mouseDownPane = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let url = link(at: point)
        if url != hoverLinkURL {
            hoverLinkURL = url
            needsDisplay = true
        }
        if let surface, surface.popup == nil,
           let split = CellSurfaceLogic.splitHit(
               atX: Double(point.x), atY: Double(point.y),
               cellWidth: cellWidth, cellHeight: cellHeight,
               splits: surface.splits) {
            if split.direction == .horizontal {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.resizeUpDown.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    private func paneReportsMouse(_ paneId: String) -> Bool {
        surface?.panes.first { $0.paneId == paneId }?.mouseReporting ?? false
    }

    private func sendMouse(_ event: NSEvent, point: NSPoint,
                           isDown: Bool, isDrag: Bool) {
        guard let paneId = mouseDownPane else { return }
        guard let cell = CellSurfaceLogic.cellAt(x: Double(point.x),
                                                 y: Double(point.y),
                                                 cellWidth: cellWidth,
                                                 cellHeight: cellHeight)
        else { return }
        let input: ClientPaneInputEvent = .mouse(
            kind: CellInputMapper.mouseKind(isDown: isDown, isDrag: isDrag,
                                            button: CellInputMapper.mouseButton(
                                                eventNumber: event.buttonNumber)),
            position: .cell(column: UInt16(clamping: cell.col),
                            row: UInt16(clamping: cell.row)),
            geometry: nil,
            modifiers: CellInputMapper.modifierBits(event.modifierFlags),
            lines: 0)
        onPaneInput?(paneId, [input])
    }

    // MARK: Input — wheel

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let gestureStarted = event.phase == .began
        var target: InputTarget
        if let popup = surface.popup {
            target = .popup(popup.terminalId)
        } else {
            guard let paneId = CellSurfaceLogic.paneId(atX: Double(point.x),
                                                       atY: Double(point.y),
                                                       cellWidth: cellWidth,
                                                       cellHeight: cellHeight,
                                                       panes: surface.panes)
            else { return }
            target = .pane(paneId)
        }
        let lines = wheel.lines(target: target,
                                deltaY: Double(event.scrollingDeltaY),
                                cellHeight: cellHeight,
                                gestureStarted: gestureStarted)
        guard lines != 0 else { return }
        let position = CellSurfaceLogic.cellAt(x: Double(point.x),
                                               y: Double(point.y),
                                               cellWidth: cellWidth,
                                               cellHeight: cellHeight)
        let input: ClientPaneInputEvent = .mouse(
            kind: lines > 0 ? .scrollUp : .scrollDown,
            position: .cell(column: UInt16(clamping: position?.col ?? 0),
                            row: UInt16(clamping: position?.row ?? 0)),
            geometry: nil,
            modifiers: CellInputMapper.modifierBits(event.modifierFlags),
            lines: UInt16(clamping: abs(lines)))
        switch target {
        case .pane(let paneId): onPaneInput?(paneId, [input])
        case .popup(let terminalId): onPopupInput?(terminalId, [input])
        }
    }

    // MARK: Hyperlinks

    private func link(at point: NSPoint) -> String? {
        guard let surface else { return nil }
        let frame = surface.popup?.frame ?? surface.frame
        guard let cell = CellSurfaceLogic.cellAt(x: Double(point.x),
                                                 y: Double(point.y),
                                                 cellWidth: cellWidth,
                                                 cellHeight: cellHeight),
              cell.col < Int(frame.width), cell.row < Int(frame.height)
        else { return nil }
        let data = frame.cells[cell.row * Int(frame.width) + cell.col]
        guard let index = data.hyperlink, Int(index) < frame.hyperlinks.count
        else { return nil }
        return frame.hyperlinks[Int(index)]
    }

    // MARK: Right-click pane menu

    /// Pane the context menu was opened on.
    private var contextPaneId: String?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface, surface.popup == nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let paneId = CellSurfaceLogic.paneId(
                atX: Double(point.x), atY: Double(point.y),
                cellWidth: cellWidth, cellHeight: cellHeight,
                panes: surface.panes)
        else { return nil }
        contextPaneId = paneId
        let menu = NSMenu()
        menu.addItem(withTitle: "Split Right", action: #selector(menuSplitRight),
                     keyEquivalent: "d").keyEquivalentModifierMask = .command
        let down = menu.addItem(withTitle: "Split Down",
                                action: #selector(menuSplitDown), keyEquivalent: "d")
        down.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Zoom Pane", action: #selector(menuZoomPane),
                     keyEquivalent: "\r").keyEquivalentModifierMask = .shift
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Pane", action: #selector(menuClosePane),
                     keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func menuSplitRight() {
        onRequest?("pane.split", ["direction": "right", "focus": true])
    }

    @objc private func menuSplitDown() {
        onRequest?("pane.split", ["direction": "down", "focus": true])
    }

    @objc private func menuZoomPane() {
        if let paneId = contextPaneId {
            onRequest?("pane.zoom", ["pane_id": paneId])
        }
    }

    @objc private func menuClosePane() {
        if let paneId = contextPaneId {
            onRequest?("pane.close", ["pane_id": paneId])
        }
    }

    // MARK: Key equivalents (copy/paste)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers ?? ""
        // Cmd-D / Cmd-Shift-D: split right / down (herdr-gpui bindings).
        if flags.contains(.command), !flags.contains(.option), key == "d" {
            onRequest?("pane.split", ["direction": flags.contains(.shift) ? "down" : "right",
                                      "focus": true])
            return true
        }
        // Cmd-Option-Arrows: focus the neighboring pane.
        if flags.contains(.command), flags.contains(.option) {
            switch event.keyCode {
            case 123: onRequest?("pane.focus_direction", ["direction": "left"]); return true
            case 124: onRequest?("pane.focus_direction", ["direction": "right"]); return true
            case 125: onRequest?("pane.focus_direction", ["direction": "down"]); return true
            case 126: onRequest?("pane.focus_direction", ["direction": "up"]); return true
            default: break
            }
        }
        // Shift-Cmd-Return: zoom the focused pane.
        if flags.contains(.command), flags.contains(.shift),
           event.keyCode == 36 {
            if let paneId = focusedPaneId {
                onRequest?("pane.zoom", ["pane_id": paneId])
            }
            return true
        }
        guard flags.contains(.command) else { return false }
        if key == "c", selectionAnchor != nil {
            copy(self)
            return true
        }
        if key == "v", let text = NSPasteboard.general.string(forType: .string),
           !text.isEmpty {
            send(.paste(text))
            return true
        }
        return false
    }
}

// MARK: - color bridging

extension NSColor {
    convenience init(rgb packed: UInt32) {
        self.init(calibratedRed: CGFloat((packed >> 16) & 255) / 255,
                  green: CGFloat((packed >> 8) & 255) / 255,
                  blue: CGFloat(packed & 255) / 255,
                  alpha: 1)
    }
}
