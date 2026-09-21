import Foundation

/// Pure layout logic of the cell canvas: pane hit-testing, popup centering,
/// and cursor shapes (DECSCUSR classes from herdr-gpui terminal_painter.rs).
enum CellSurfaceLogicTests {
    static func register() {
        let ok1 = TestRegistry.add("surface: pane hit-test uses inner rects") {
            let panes = [
                PaneSurfacePane(paneId: "left", contentRevision: 1,
                                rect: SurfaceRect(x: 0, y: 0, width: 40, height: 24),
                                innerRect: SurfaceRect(x: 1, y: 1, width: 38, height: 22),
                                scrollbarRect: nil, scroll: nil, focused: true,
                                mouseReporting: false, sgrPixelMouse: false,
                                alternateScreenActive: false,
                                pixelWidth: 380, pixelHeight: 440),
                PaneSurfacePane(paneId: "right", contentRevision: 1,
                                rect: SurfaceRect(x: 40, y: 0, width: 40, height: 24),
                                innerRect: SurfaceRect(x: 41, y: 1, width: 38, height: 22),
                                scrollbarRect: nil, scroll: nil, focused: false,
                                mouseReporting: false, sgrPixelMouse: false,
                                alternateScreenActive: false,
                                pixelWidth: 380, pixelHeight: 440),
            ]
            let cw = 10.0, ch = 20.0
            // Inside left pane's inner rect.
            expectEq(CellSurfaceLogic.paneId(atX: 15, atY: 40, cellWidth: cw,
                                             cellHeight: ch, panes: panes),
                     "left", "left pane")
            // Inside right pane.
            expectEq(CellSurfaceLogic.paneId(atX: 500, atY: 40, cellWidth: cw,
                                             cellHeight: ch, panes: panes),
                     "right", "right pane")
            // Border column (x=400 → col 40 = right pane's outer border) misses.
            expect(CellSurfaceLogic.paneId(atX: 400, atY: 40, cellWidth: cw,
                                           cellHeight: ch, panes: panes) == nil,
                   "border misses")
            // Below inner rect bottom (row 23) misses.
            expect(CellSurfaceLogic.paneId(atX: 15, atY: 465, cellWidth: cw,
                                           cellHeight: ch, panes: panes) == nil,
                   "bottom border misses")
        }
        let ok2 = TestRegistry.add("surface: popup centers and floors") {
            let origin = CellSurfaceLogic.popupOrigin(mainCols: 80, mainRows: 24,
                                                      popupCols: 20, popupRows: 10,
                                                      cellWidth: 10, cellHeight: 20)
            expectEq(origin.x, 300.0, "x centered")
            expectEq(origin.y, 140.0, "y centered")
            // Popup larger than main: saturates to 0.
            let big = CellSurfaceLogic.popupOrigin(mainCols: 10, mainRows: 5,
                                                   popupCols: 20, popupRows: 10,
                                                   cellWidth: 10, cellHeight: 20)
            expectEq(big.x, 0.0, "x clamped")
            expectEq(big.y, 0.0, "y clamped")
        }
        let ok3 = TestRegistry.add("surface: cursor shapes per DECSCUSR") {
            // Default (0..2) and blink block variants → full block.
            func rect(_ shape: UInt8) -> (Double, Double, Double, Double) {
                let r = CellSurfaceLogic.cursorRect(x: 3, y: 4, shape: shape,
                                                    cellWidth: 10, cellHeight: 20)
                return (r.x, r.y, r.w, r.h)
            }
            expectEq(rect(0).0, 30.0, "block x")
            expectEq(rect(0).2, 10.0, "block w")
            expectEq(rect(4).1, 98.0, "underline y")
            expectEq(rect(4).3, 2.0, "underline h")
            expectEq(rect(6).2, 2.0, "bar w")
            expectEq(rect(6).3, 20.0, "bar h")
        }
        let ok4 = TestRegistry.add("surface: cell coordinate math") {
            let cell = CellSurfaceLogic.cellAt(x: 155, y: 41, cellWidth: 10, cellHeight: 20)
            expectEq(cell?.col ?? -1, 15, "col")
            expectEq(cell?.row ?? -1, 2, "row")
            // Negative coordinates clamp out of bounds.
            expect(CellSurfaceLogic.cellAt(x: -1, y: 10, cellWidth: 10,
                                           cellHeight: 20) == nil, "negative x")
        }
        let ok5 = TestRegistry.add("surface: clamped cell and word bounds") {
            let c = CellSurfaceLogic.clampedCell(x: -5, y: 999, cellWidth: 9,
                                                 cellHeight: 17, cols: 80, rows: 24)
            expectEq(c.col, 0, "negative x clamps to 0")
            expectEq(c.row, 23, "y clamps to last row")
            let mid = CellSurfaceLogic.clampedCell(x: 45, y: 51, cellWidth: 9,
                                                   cellHeight: 17, cols: 80, rows: 24)
            expectEq(mid.col, 5, "mid col")
            expectEq(mid.row, 3, "mid row")
            // "  hello world " on row 2 of a 12-wide row.
            let row = 2, width = 16
            var cells = (0..<width).map { _ in
                CellData(symbol: " ", fg: 0, bg: 0, modifier: 0, skip: false,
                         hyperlink: nil)
            }
            for (i, ch) in "hello".enumerated() { cells[2 + i].symbol = String(ch) }
            for (i, ch) in "world".enumerated() { cells[8 + i].symbol = String(ch) }
            let grid = (0..<3 * width).map { rowCells in
                rowCells >= row * width && rowCells < (row + 1) * width
                    ? cells[rowCells - row * width]
                    : CellData(symbol: " ", fg: 0, bg: 0, modifier: 0,
                               skip: false, hyperlink: nil)
            }
            let start = CellSurfaceLogic.wordStart(cells: grid, width: width,
                                                   col: 3, row: row)
            let end = CellSurfaceLogic.wordEnd(cells: grid, width: width,
                                               col: 3, row: row)
            expectEq(start.col, 2, "word start")
            expectEq(end.col, 6, "word end")
            // A space cell selects just itself.
            let spaceStart = CellSurfaceLogic.wordStart(cells: grid, width: width,
                                                        col: 0, row: row)
            expectEq(spaceStart.col, 0, "space start")
        }
        let ok6 = TestRegistry.add("surface: streaming selection spans") {
            let spans = CellSurfaceLogic.rowSpans(
                anchor: (col: 10, row: 2), head: (col: 4, row: 5), x0: 0, x1: 79)
            expectEq(spans.count, 4, "span count")
            expectEq(spans[0].row, 2, "first row")
            expectEq(spans[0].from, 10, "first from")
            expectEq(spans[0].to, 79, "first to end of line")
            expectEq(spans[1].from, 0, "middle full")
            expectEq(spans[1].to, 79, "middle full to")
            expectEq(spans[3].row, 5, "last row")
            expectEq(spans[3].from, 0, "last from 0")
            expectEq(spans[3].to, 4, "last to head col")
            // Same row: a simple run between the two columns.
            let single = CellSurfaceLogic.rowSpans(
                anchor: (col: 30, row: 7), head: (col: 20, row: 7), x0: 0, x1: 79)
            expectEq(single.count, 1, "single row span")
            expectEq(single[0].from, 20, "single from")
            expectEq(single[0].to, 30, "single to")
            // Backwards drag (head above anchor) normalizes identically.
            let reverse = CellSurfaceLogic.rowSpans(
                anchor: (col: 4, row: 5), head: (col: 10, row: 2), x0: 0, x1: 79)
            expectEq(reverse.first?.to, 79, "reverse same spans")
            // Pane-constrained bounds clip the spans.
            let clipped = CellSurfaceLogic.rowSpans(
                anchor: (col: 1, row: 0), head: (col: 2, row: 2), x0: 1, x1: 38)
            expectEq(clipped[0].from, 1, "clip from x0")
            expectEq(clipped[0].to, 38, "clip to x1")
        }
        let ok7 = TestRegistry.add("surface: span snaps to content") {
            let width = 20
            func cell(_ s: String) -> CellData {
                CellData(symbol: s, fg: 0, bg: 0, modifier: 0, skip: false,
                         hyperlink: nil)
            }
            // Row "     hello     " in cols 0..19.
            var rowCells = (0..<width).map { _ in cell(" ") }
            for (i, ch) in "hello".enumerated() { rowCells[5 + i] = cell(String(ch)) }
            var cells: [CellData] = []
            for _ in 0..<3 { cells.append(contentsOf: (0..<width).map { _ in cell(" ") }) }
            cells.append(contentsOf: rowCells)
            let bounds = CellSurfaceLogic.spanContentBounds(
                cells: cells, width: width, row: 3, from: 2, to: 15)
            expectEq(bounds?.from ?? -1, 5, "snap from")
            expectEq(bounds?.to ?? -1, 9, "snap to")
            // All-blank span → nil (no highlight).
            let blank = CellSurfaceLogic.spanContentBounds(
                cells: cells, width: width, row: 0, from: 0, to: 19)
            expect(blank == nil, "blank span is nil")
        }
        expect(ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7, "registration")
    }
}
