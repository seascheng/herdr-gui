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

    /// Centered popup origin, floored, saturating at zero.
    static func popupOrigin(mainCols: Int, mainRows: Int, popupCols: Int,
                            popupRows: Int, cellWidth: Double, cellHeight: Double)
        -> (x: Double, y: Double) {
        let x = (Double(mainCols - popupCols) * cellWidth / 2).rounded(.down)
        let y = Double(mainRows - popupRows) * cellHeight / 2
        return (max(x, 0), max(y, 0))
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

/// Paints the daemon's `PaneSurfaceFrame` cell grid (splits and borders
/// included — the frame IS the whole tab surface) and routes semantic input
/// pane-relatively. No terminal emulator: cells in, glyphs out.
final class CellSurfaceView: NSView, NSTextInputClient {
    var theme = CellTheme.defaults

    // Main-thread lifecycle callbacks.
    var onPaneInput: ((String, [ClientPaneInputEvent]) -> Void)?
    var onPopupInput: ((String, [ClientPaneInputEvent]) -> Void)?
    var onResize: ((ClientSurfaceSize, UInt32, UInt32) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onFocusedTitle: ((String?) -> Void)?

    private(set) var surface: PaneSurfaceFrame?
    private var font: NSFont
    private var boldFont: NSFont
    private var italicFont: NSFont
    private(set) var cellWidth: Double = 8
    private(set) var cellHeight: Double = 17

    /// Shaped-glyph cache: (fg | style<<24) → symbol → CTLine. Bounded; a
    /// theme or font change clears it.
    private var glyphCache: [UInt32: [String: CTLine]] = [:]
    private var glyphCacheCount = 0
    private static let glyphCacheLimit = 4096

    private var wheel = WheelAccumulator()
    private var lastReportedSize = ClientSurfaceSize(cols: 0, rows: 0)
    private var resizeDebounce: DispatchWorkItem?
    private var markedText: String?
    private var hoverLinkURL: String?

    // Selection state (cell coordinates over the whole frame).
    private var selectionAnchor: (col: Int, row: Int)?
    private var selectionHead: (col: Int, row: Int)?
    private var isDraggingSelection = false
    private var mouseDownPane: String?

    override var acceptsFirstResponder: Bool { true }

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

    private func measureCells() {
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        cellHeight = Double(ascent + descent).rounded(.up)
        // Monospace advance of a wide-enough sample.
        let sample = "M" as CFString
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: sample as String, attributes: attrs))
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        cellWidth = max(width.rounded(.up), 1)
        glyphCache.removeAll()
        glyphCacheCount = 0
        scheduleResize()
    }

    func setFontSize(_ point: Double) {
        font = NSFont.monospacedSystemFont(ofSize: point, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: point, weight: .bold)
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        measureCells()
        needsDisplay = true
    }

    // MARK: Surface updates (main thread)

    func update(surface newSurface: PaneSurfaceFrame) {
        guard newSurface.surfaceRevision != surface?.surfaceRevision
            || newSurface.projectionRevision != surface?.projectionRevision
            || newSurface.bootId != surface?.bootId
        else { return }
        surface = newSurface
        needsDisplay = true
        scheduleResize()
        if ProcessInfo.processInfo.environment["HERDR_DUMP_CELLS"] == "1" {
            dumpCells()
        }
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

    // MARK: Drawing
    /// Top-left origin: every grid computation (rows, hit-testing, mouse
    /// coordinates) is written in terminal top-down space.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let surface, surface.frame.width > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        // Pure-CG pipeline: rects via fill(CGRect), glyphs via CTLineDraw.
        // The view is flipped, so all coordinates are terminal top-down.
        fill(context, bounds, color: theme.background, alpha: 1)

        let frame = surface.frame
        let width = Int(frame.width)

        // Pass 1: background spans per row.
        for row in 0..<Int(frame.height) {
            let slice = row * width..<(row + 1) * width
            var start = slice.lowerBound
            var bg = theme.cellColors(frame.cells[start]).bg
            var index = start + 1
            while index <= slice.upperBound {
                let nextBg = index < slice.upperBound
                    ? theme.cellColors(frame.cells[index]).bg : bg
                if index == slice.upperBound || nextBg != bg {
                    fill(context,
                         CGRect(x: Double(start % width) * cellWidth,
                                y: Double(row) * cellHeight,
                                width: Double(index - start) * cellWidth,
                                height: cellHeight),
                         color: bg, alpha: 1)
                    if index < slice.upperBound {
                        start = index
                        bg = nextBg
                    }
                }
                index += 1
            }
        }

        // Pass 2: glyphs. Flipped view: translate to the baseline, flip the
        // local CTM, draw — the classic flipped-context CoreText recipe.
        let ascent = fontBaselineOffset()
        for (index, cell) in frame.cells.enumerated() where !cell.skip {
            guard !cell.symbol.isEmpty, cell.symbol != " " else { continue }
            let line = shapedLine(symbol: cell.symbol, styleKey: theme.shapeKey(cell))
            let position = CGPoint(x: CGFloat(Double(index % width) * cellWidth),
                                   y: CGFloat(Double(index / width) * cellHeight))
            context.saveGState()
            // CTLineDraw draws at the context's accumulated text position;
            // reset it or glyphs chain onto the previous one.
            context.textMatrix = CGAffineTransform.identity
            context.translateBy(x: position.x, y: position.y + ascent)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        // Pass 3: decorations at exact cell-grid coordinates.
        for (index, cell) in frame.cells.enumerated() {
            let colors = theme.cellColors(cell)
            let base = CGRect(x: Double(index % width) * cellWidth,
                              y: Double(index / width) * cellHeight,
                              width: cellWidth, height: 1)
            if cell.modifier & CellTheme.underline != 0 {
                fill(context, base.offsetBy(dx: 0, dy: cellHeight - 2),
                     color: colors.fg, alpha: 1)
            }
            if cell.modifier & CellTheme.strikethrough != 0 {
                fill(context, base.offsetBy(dx: 0, dy: cellHeight / 2),
                     color: colors.fg, alpha: 1)
            }
            if let link = cell.hyperlink, Int(link) < frame.hyperlinks.count {
                fill(context, base.offsetBy(dx: 0, dy: cellHeight - 1),
                     color: colors.fg, alpha: 1)
            }
        }

        // Selection overlay.
        if let anchor = selectionAnchor, let head = selectionHead {
            let rect = selectionRect(anchor: anchor, head: head, frame: frame)
            fill(context, rect, color: 0x999999, alpha: 0.35)
        }

        // Cursor (50% alpha over content).
        if let cursor = frame.cursor, cursor.visible,
           cursor.x < frame.width, cursor.y < frame.height {
            let rect = CellSurfaceLogic.cursorRect(
                x: cursor.x, y: cursor.y, shape: cursor.shape,
                cellWidth: cellWidth, cellHeight: cellHeight)
            fill(context, CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h),
                 color: theme.cursor, alpha: 0.5)
        }

        // Popup overlay: centered, after everything.
        if let popup = surface.popup {
            let origin = CellSurfaceLogic.popupOrigin(
                mainCols: width, mainRows: Int(frame.height),
                popupCols: Int(popup.frame.width), popupRows: Int(popup.frame.height),
                cellWidth: cellWidth, cellHeight: cellHeight)
            let box = CGRect(x: origin.x, y: origin.y,
                             width: Double(popup.frame.width) * cellWidth,
                             height: Double(popup.frame.height) * cellHeight)
            fill(context, box, color: theme.background, alpha: 1)
            stroke(context, box, color: theme.foreground, alpha: 0.6)
            drawFrame(popup.frame, context: context,
                      originX: origin.x, originY: origin.y)
        }
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

    private func drawFrame(_ frame: FrameData, context: CGContext,
                           originX: Double, originY: Double) {
        let ascent = fontBaselineOffset()
        for (index, cell) in frame.cells.enumerated() where !cell.skip {
            guard !cell.symbol.isEmpty, cell.symbol != " " else { continue }
            let line = shapedLine(symbol: cell.symbol, styleKey: theme.shapeKey(cell))
            let position = CGPoint(
                x: CGFloat(originX + Double(index % Int(frame.width)) * cellWidth),
                y: CGFloat(originY + Double(index / Int(frame.width)) * cellHeight))
            context.saveGState()
            context.textMatrix = CGAffineTransform.identity
            context.translateBy(x: position.x, y: position.y + ascent)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    private func fontBaselineOffset() -> Double {
        Double(CTFontGetAscent(font as CTFont)).rounded(.down)
    }

    private func shapedLine(symbol: String, styleKey: UInt32) -> CTLine {
        if let cached = glyphCache[styleKey]?[symbol] {
            return cached
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if styleKey >> 24 & UInt32(CellTheme.bold) != 0 { attributes[.font] = boldFont }
        if styleKey >> 24 & UInt32(CellTheme.italic) != 0 { attributes[.font] = italicFont }
        attributes[.foregroundColor] = NSColor(rgb: styleKey & 0xffffff)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: symbol, attributes: attributes))
        if glyphCacheCount < Self.glyphCacheLimit {
            glyphCache[styleKey, default: [:]][symbol] = line
            glyphCacheCount += 1
        }
        return line
    }

    // MARK: Selection

    private func selectionRect(anchor: (col: Int, row: Int),
                               head: (col: Int, row: Int),
                               frame: FrameData) -> NSRect {
        let row0 = min(anchor.row, head.row)
        let row1 = max(anchor.row, head.row)
        let col0 = min(anchor.col, head.col)
        let col1 = max(anchor.col, head.col)
        return NSRect(
            x: Double(col0) * cellWidth,
            y: Double(row0) * cellHeight,
            width: Double(col1 - col0 + 1) * cellWidth,
            height: Double(row1 - row0 + 1) * cellHeight)
    }

    func copy(_ sender: Any?) {
        guard let surface, let anchor = selectionAnchor, let head = selectionHead
        else { return }
        let frame = surface.popup?.frame ?? surface.frame
        let row0 = min(anchor.row, head.row), row1 = max(anchor.row, head.row)
        let col0 = min(anchor.col, head.col), col1 = max(anchor.col, head.col)
        var lines: [String] = []
        for row in row0...min(row1, Int(frame.height) - 1) {
            var line = ""
            for col in col0...min(col1, Int(frame.width) - 1) {
                let cell = frame.cells[row * Int(frame.width) + col]
                if !cell.skip { line += cell.symbol }
            }
            lines.append(line)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Input — keyboard

    override func keyDown(with event: NSEvent) {
        // Printable text and IME go through interpretKeyEvents → insertText
        // → TextCommit; non-printables map to semantic Key events.
        let chars = event.charactersIgnoringModifiers ?? ""
        if let key = CellInputMapper.keyEvent(keyCode: event.keyCode, chars: chars,
                                              modifierFlags: event.modifierFlags,
                                              isRepeat: event.isARepeat) {
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

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = nil
        guard let text = string as? String, !text.isEmpty else { return }
        send(.textCommit(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange,
                       replacementRange: NSRange) {
        markedText = string as? String
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
        // Place IME candidates near the focused pane's cursor cell.
        guard let surface else { return .zero }
        let frame = surface.popup?.frame ?? surface.frame
        guard let cursor = frame.cursor else { return .zero }
        let rect = CellSurfaceLogic.cursorRect(x: cursor.x, y: cursor.y, shape: 0,
                                               cellWidth: cellWidth,
                                               cellHeight: cellHeight)
        var viewRect = NSRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        viewRect = convert(viewRect, to: nil)
        return window?.convertToScreen(viewRect) ?? .zero
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
        selectionAnchor = CellSurfaceLogic.cellAt(x: Double(point.x), y: Double(point.y),
                                                  cellWidth: cellWidth,
                                                  cellHeight: cellHeight)
        selectionHead = selectionAnchor
        isDraggingSelection = true
        mouseDownPane = CellSurfaceLogic.paneId(atX: Double(point.x),
                                                atY: Double(point.y),
                                                cellWidth: cellWidth,
                                                cellHeight: cellHeight,
                                                panes: surface.panes)
        if let paneId = mouseDownPane, paneReportsMouse(paneId) {
            sendMouse(event, point: point, isDown: true, isDrag: false)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDraggingSelection {
            selectionHead = CellSurfaceLogic.cellAt(x: Double(point.x),
                                                    y: Double(point.y),
                                                    cellWidth: cellWidth,
                                                    cellHeight: cellHeight)
            needsDisplay = true
        }
        if let paneId = mouseDownPane, paneReportsMouse(paneId) {
            sendMouse(event, point: point, isDown: true, isDrag: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A zero-extent drag is a click, not a selection.
        if let anchor = selectionAnchor, let head = selectionHead,
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
    }

    private func paneReportsMouse(_ paneId: String) -> Bool {
        surface?.panes.first { $0.paneId == paneId }?.mouseReporting ?? false
    }

    private func sendMouse(_ event: NSEvent, point: NSPoint,
                           isDown: Bool, isDrag: Bool) {
        guard let surface, let paneId = mouseDownPane else { return }
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
        if surface.popup != nil, surface.popup.map(\.terminalId) != nil {
            // Mouse only routes to panes; popups take wheel/keys separately.
        }
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

    // MARK: Paste / copy equivalents


    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers else { return false }
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
