import Cocoa
import Combine
import GhosttyKit

// MARK: - Full-app surface host
//
// One ghostty surface mirrors herdr's ENTIRE app frame (the same stream the
// native TUI renders). Native chrome overlays herdr's own sidebar/tab bar:
// herdr's layout reserves 26 columns on the left and 1 row on top for its
// chrome (see snapshot layout areas), so the native sidebar/top-strip cover
// exactly those cells and only the content area shows through.

/// Mirror surface variant for herdr pages: herdr owns ALL interaction
/// (its TUI renders its own context menus inside the app frame), so
/// ghostty's native context menu never appears. Overriding menu(for:)
/// also covers the ctrl+click path — AppKit asks for the menu BEFORE
/// dispatching mouse events, so event monitors cannot intercept it.
final class MirrorSurfaceView: Ghostty.SurfaceView {
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

final class TerminalSurfaceHost: NSView {
    private var surfaceView: Ghostty.SurfaceView?
    private var scrollView: SurfaceScrollView?
    var session: HerdrAttachSession?
    private(set) var scrollChannel: HerdrScrollChannel?
    private var lastGrid: (UInt16, UInt16) = (0, 0)
    private var resizeDebounce: DispatchWorkItem?
    private var awaitingFullFrame: (UInt16, UInt16)?

    private var reconnectAttempt = 0
    private var sizeCancellable: Any?
    private var cellSizeCancellable: Any?

    private var isRendererPresented = false
    private var inputRouter: TerminalInputRouter?
    private static let clearLocalTerminal = Array("\u{1B}[3J\u{1B}[2J\u{1B}[H".utf8)

    /// herdr's own chrome in app-frame cells: sidebar columns and top tab-bar
    /// rows (from the snapshot layout area). The surface keeps the FULL app
    /// grid, but the view is offset so herdr's chrome falls outside the
    /// clipped bounds — only the content area shows, and the native sidebar /
    /// tab strip own their regions exclusively.
    var chromeSidebarCols: CGFloat = 26
    var chromeTopRows: CGFloat = 1
    var focusedPaneRect = NSRect(x: 26, y: 1, width: 0, height: 0)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        applyCropOffset(force: true)
        if ProcessInfo.processInfo.environment["HERDR_DUMP_FRAMES"] == "1" {
            dumpGeometryIfChanged()
        }
    }

    /// Authoritative grid geometry from the live surface (cmux fork's
    /// grid_metrics): cell size AND grid origin in logical points. The
    /// padding is NOT a config constant — it differs per backing scale
    /// (mixed-DPI), so guessing it from the config file breaks the crop
    /// and the mouse coordinates on secondary displays.
    private func liveGridGeometry() -> (cell: NSSize, pad: NSSize)? {
        guard let surface = surfaceView?.surface else { return nil }
        var m = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &m),
              m.cell_width > 0, m.cell_height > 0
        else { return nil }
        lastCellSize = NSSize(width: m.cell_width, height: m.cell_height)
        lastPad = NSSize(width: m.padding_left, height: m.padding_top)
        return (lastCellSize, lastPad)
    }

    /// Offset the surface so herdr's own chrome (sidebar columns, top tab
    /// rows, plus the surface's real grid origin) falls outside the clipped
    /// bounds. Re-asserted on every applied frame: nothing else may own the
    /// scroll frame, and a silently clobbered offset would leak herdr's
    /// chrome into the content area.
    private func applyCropOffset(force: Bool) {
        guard let scroll = scrollView else { return }
        let geo = liveGridGeometry() ?? (lastCellSize, lastPad)
        let dx = chromeSidebarCols * geo.cell.width + geo.pad.width
        let dy = chromeTopRows * geo.cell.height + geo.pad.height
        let frame = NSRect(
            x: -dx,
            y: -dy,
            width: bounds.width + dx,
            height: bounds.height + dy
        )
        guard force || scroll.frame != frame else { return }
        scroll.translatesAutoresizingMaskIntoConstraints = true
        scroll.frame = frame
        scroll.needsLayout = true
    }

    /// Env-gated geometry drift log (`HERDR_DUMP_FRAMES=1` writes to
    /// /tmp/herdr-frames.log). Kept from the mixed-DPI investigation:
    /// any future crop report is diagnosed in seconds from this dump.
    private var lastDumpedGeometry = ""

    private func dumpGeometryIfChanged() {
        guard ProcessInfo.processInfo.environment["HERDR_DUMP_FRAMES"] == "1",
              let scroll = scrollView,
              let view = surfaceView
        else { return }
        let key = "\(scroll.frame)|\(view.frame)|\(chromeSidebarCols)|\(lastCellSize.width)"
        guard key != lastDumpedGeometry else { return }
        lastDumpedGeometry = key
        let line = "GEOM scroll=\(scroll.frame) surface=\(view.frame) "
            + "chrome=\(chromeSidebarCols) cell=\(lastCellSize) pad=\(lastPad)\n"
        DiagLog.frames(line)
    }

    private var lastDumpedSequence: UInt64 = 0

    /// Env-gated frame flow log (HERDR_DUMP_FRAMES=1 → /tmp/herdr-frames.log):
    /// one line per incoming app frame — accepted or rejected, with the
    /// reason — so delivery stalls are separable from render-side ones.
    private func dumpFrame(sequence: UInt64, width: UInt16, height: UInt16,
                           full: Bool, byteCount: Int, note: String) {
        guard ProcessInfo.processInfo.environment["HERDR_DUMP_FRAMES"] == "1" else { return }
        let gap = lastDumpedSequence == 0 ? 0 : sequence - lastDumpedSequence
        lastDumpedSequence = sequence
        let line = "FRAME t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) "
            + "seq=\(sequence) gap=\(gap) full=\(full ? 1 : 0) bytes=\(byteCount) "
            + "grid=\(width)x\(height) \(note)\n"
        DiagLog.frames(line)
    }

    private var lastCellSize = NSSize(width: 9, height: 17)
    private var lastPad = NSSize(width: 0, height: 0)
    private var effectiveCellSize: NSSize {
        if let cell = surfaceView?.cellSize, cell.width > 0, cell.height > 0 {
            return cell
        }
        return lastCellSize
    }

    /// Attaches the mirror surface and its backing connections. The client
    /// socket path is per-session: the local herdr default, or a local
    /// endpoint of an SSH streamlocal tunnel for remote servers.
    func attach(app: ghostty_app_t,
                clientSocketPath: String = NSString(
                    string: "~/.config/herdr/herdr-client.sock").expandingTildeInPath) {
        let session = HerdrAttachSession(socketPath: clientSocketPath)
        self.session = session
        let channel = HerdrScrollChannel(clientSocketPath: clientSocketPath)
        self.scrollChannel = channel

        var config = Ghostty.SurfaceConfiguration()
        config.ioMode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.onWrite = { [weak session] bytes in
            session?.sendInput(bytes)
        }
        config.onRendererActivity = { [weak self] in
            DispatchQueue.main.async { self?.isRendererPresented = true }
        }

        let view = MirrorSurfaceView(app, baseConfig: config)
        surfaceView = view

        let scroll = SurfaceScrollView(
            contentSize: NSSize(width: 1000, height: 700),
            surfaceView: view
        )
        scrollView = scroll
        addSubview(scroll)
        // Frame is managed exclusively by layout() (clipped chrome offset).
        // No autolayout constraints: they would override the offset.
        scroll.translatesAutoresizingMaskIntoConstraints = true

        let inputRouter = TerminalInputRouter(
            host: self, session: session, scrollChannel: channel)
        inputRouter.start()
        self.inputRouter = inputRouter
        // A resize invalidates Ghostty's local grid. Apply no ANSI diff until
        // Herdr sends a full snapshot for the current grid.
        session.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                guard let self,
                      case let .terminalFrame(sequence, width, height, full, bytes) = message,
                      let surface = self.surfaceView?.surface
                else { return }
                func dump(_ note: String) {
                    self.dumpFrame(sequence: sequence, width: width, height: height,
                                   full: full, byteCount: bytes.count, note: note)
                }

                // The crop offset is re-asserted on every frame (early
                // exit when unchanged): nothing else may own the scroll
                // frame, and a silently clobbered offset leaks herdr's
                // chrome into the content area — observed live when the
                // host's layout() pass does not re-run.
                self.applyCropOffset(force: false)
                self.dumpGeometryIfChanged()

                guard let grid = self.currentGrid else {
                    dump("drop no-grid")
                    return
                }
                guard width == grid.0, height == grid.1 else {
                    dump("drop grid-mismatch local=\(grid.0)x\(grid.1)")
                    self.requestFullFrame(replacePending: false)
                    return
                }
                let awaitingThisGrid = self.awaitingFullFrame.map {
                    $0.0 == grid.0 && $0.1 == grid.1
                } ?? false
                guard !awaitingThisGrid || full else {
                    dump("drop awaiting-full")
                    self.requestFullFrame(replacePending: false)
                    return
                }
                if full,
                   !self.prepareForFullFrame(surface: surface, grid: grid) {
                    dump("drop prepare-failed")
                    self.requestFullFrame(replacePending: false)
                    return
                }

                bytes.withUnsafeBufferPointer { buffer in
                    if let base = buffer.baseAddress {
                        ghostty_surface_process_output(surface, base, UInt(buffer.count))
                    }
                }
                if full { self.awaitingFullFrame = nil }
                self.isRendererPresented = false
                dump(full ? "applied full" : "applied")
                ghostty_surface_draw(surface)
            }
        }

        session.onDisconnect = { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleReconnect() }
        }
        session.onFrameGap = { gaps in
            HerdrLog.error("frame gap: \(gaps) dropped (baseline holds)")
        }

        // First sane grid connects; later changes request a new ANSI baseline.
        sizeCancellable = view.$surfaceSize.sink { [weak self] size in
            guard let self,
                  let size,
                  size.columns >= 10,
                  size.rows >= 4
            else { return }
            let grid = (UInt16(clamping: size.columns), UInt16(clamping: size.rows))
            guard grid != self.lastGrid else { return }
            let first = self.lastGrid == (0, 0)
            self.lastGrid = grid
            self.awaitingFullFrame = grid
            if first {
                self.connect(cols: grid.0, rows: grid.1)
            } else {
                self.requestFullFrame(replacePending: true)
            }
        }
        cellSizeCancellable = view.$cellSize.sink { [weak self] cell in
            guard let self, cell.width > 0, cell.height > 0 else { return }
            self.lastCellSize = cell
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }

        // Repair only until the renderer confirms a presented frame. Normal
        // frames use draw(); rebuilding a healthy renderer is wasted GPU work.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.surfaceView != nil else {
                timer.invalidate()
                return
            }
            guard !self.isRendererPresented,
                  self.window != nil,
                  !self.isHidden
            else { return }
            self.rebuildRenderer()
        }
        updateSurfaceVisibility()

    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWindow.didChangeBackingPropertiesNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        updateSurfaceVisibility()
    }

    @objc private func occlusionChanged() {
        updateSurfaceVisibility()
    }

    @objc private func screenChanged() {
        isRendererPresented = false
        updateSurfaceVisibility()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateSurfaceVisibility()
    }

    private func updateSurfaceVisibility() {
        guard let surface = surfaceView?.surface else { return }
        let visible = superview != nil
            && window?.occlusionState.contains(.visible) == true
        ghostty_surface_set_occlusion(surface, visible)
        guard visible else {
            isRendererPresented = false
            return
        }
        isRendererPresented = false
        rebuildRenderer()
    }

    var cellHeight: Double {
        Double((liveGridGeometry()?.cell.height) ?? effectiveCellSize.height)
    }

    private func rebuildRenderer() {
        guard let surface = surfaceView?.surface else { return }
        _ = ghostty_surface_rebuild_renderer(surface)
    }

    func shutdown() {
        inputRouter?.stop()
        inputRouter = nil
        session?.close()
    }

    var keyView: NSView? { surfaceView }

    func gridCell(for event: NSEvent) -> NSPoint? {
        guard event.window === window,
              let scroll = scrollView,
              bounds.width > 0
        else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return nil }
        let geo = liveGridGeometry() ?? (lastCellSize, lastPad)
        guard geo.cell.width > 0, geo.cell.height > 0 else { return nil }
        let surfaceX = location.x - scroll.frame.minX - geo.pad.width
        let surfaceY = location.y - scroll.frame.minY - geo.pad.height
        return NSPoint(x: Int(surfaceX / geo.cell.width), y: Int(surfaceY / geo.cell.height))
    }

    private func prepareForFullFrame(
        surface: ghostty_surface_t,
        grid: (UInt16, UInt16)
    ) -> Bool {
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics) else { return false }
        if metrics.columns != grid.0 || metrics.rows != grid.1 {
            var resolved = ghostty_surface_size_s()
            guard ghostty_surface_set_grid_size(surface, grid.0, grid.1, &resolved) else {
                return false
            }
        }
        Self.clearLocalTerminal.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                ghostty_surface_process_output(surface, base, UInt(buffer.count))
            }
        }
        return true
    }
    var currentGrid: (UInt16, UInt16)? {
        guard let size = surfaceView?.surfaceSize,
              size.columns >= 10,
              size.rows >= 4
        else { return nil }
        return (UInt16(clamping: size.columns), UInt16(clamping: size.rows))
    }

    // MARK: session lifecycle

    private func connect(cols: UInt16, rows: UInt16) {
        let session = self.session
        awaitingFullFrame = (cols, rows)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try session?.connectApp(cols: cols, rows: rows)
                DispatchQueue.main.async { self?.reconnectAttempt = 0 }
            } catch {
                DispatchQueue.main.async { self?.scheduleReconnect() }
            }
        }
    }

    /// Re-connect with the current grid; exponential backoff capped at 4s.
    /// A transiently unreported surface size must not strand the mirror:
    /// fall back to the last known grid instead of resetting it — a reset
    /// left the app showing a frozen frame until the next window resize.
    private func scheduleReconnect() {
        guard let session, !session.isAttached else { return }
        guard reconnectGrid() != nil else { return }
        let delay = min(0.5 * pow(2.0, Double(reconnectAttempt)), 4.0)
        reconnectAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.window != nil else { return }
            guard let grid = self.reconnectGrid() else { return }
            self.connect(cols: grid.0, rows: grid.1)
        }
    }

    private func reconnectGrid() -> (UInt16, UInt16)? {
        if let grid = currentGrid { return grid }
        return lastGrid.0 >= 10 && lastGrid.1 >= 4 ? lastGrid : nil
    }

    /// Requests a new server baseline for the current Ghostty grid. A normal
    /// resize replaces a stale pending request; recovery keeps an existing
    /// timer so incoming stale frames cannot starve the retry indefinitely.
    private func requestFullFrame(replacePending: Bool) {
        guard let grid = currentGrid else { return }
        awaitingFullFrame = grid
        if replacePending {
            resizeDebounce?.cancel()
            resizeDebounce = nil
        }
        guard resizeDebounce == nil else { return }

        let delay: TimeInterval = replacePending ? 0.15 : 0.03
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeDebounce = nil
            guard let latest = self.currentGrid else { return }
            self.awaitingFullFrame = latest
            self.session?.sendResize(cols: latest.0, rows: latest.1)
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

}
