import Cocoa

final class TerminalInputRouter {
    private weak var host: TerminalSurfaceHost?

    private weak var stream: MirrorStream?
    private unowned let scrollChannel: PaneScrollChannel
    private var wheelMonitor: Any?
    private var mouseMonitors: [Any] = []
    private var wheelRemainder = 0.0

    init(host: TerminalSurfaceHost, stream: MirrorStream,
         scrollChannel: PaneScrollChannel) {
        self.host = host
        self.stream = stream
        self.scrollChannel = scrollChannel
    }

    func start() {
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.forwardWheel(event) ?? event
        }
        mouseMonitors = [
            monitor(.leftMouseDown, kind: 0, button: 0),
            monitor(.leftMouseUp, kind: 1, button: 0),
            monitor(.leftMouseDragged, kind: 2, button: 0),
            monitor(.rightMouseDown, kind: 0, button: 1),
            monitor(.rightMouseUp, kind: 1, button: 1),
        ]
    }

    func stop() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }

    private func monitor(_ mask: NSEvent.EventTypeMask, kind: UInt32, button: Int) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.forwardMouse(event, kind: kind, button: button) ?? event
        }!
    }

    private func forwardWheel(_ event: NSEvent) -> NSEvent? {
        guard let host, let cell = host.gridCell(for: event) else { return event }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return event }

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            if wheelRemainder.sign != delta.sign { wheelRemainder = 0 }
            wheelRemainder += delta
            lines = Int(abs(wheelRemainder) / host.cellHeight)
            guard lines > 0 else { return nil }
            wheelRemainder -= Double(lines) * host.cellHeight * (wheelRemainder < 0 ? -1 : 1)
        } else {
            lines = max(1, Int(abs(delta)))
        }

        let channel = scrollChannel
        let pane = host.focusedPaneRect
        // Mouse-report apps (alt-screen TUIs: herdr reports MouseCapture
        // on) must receive wheel through the app input path — the TUI's
        // own routing, identical to a native herdr client — because the
        // AttachScroll channel drives herdr's server-side scrollback
        // viewport, which renders alt-screen content corrupted. Plain
        // shells keep the channel's exact-line scrollback.
        if !host.mouseCaptureActive, channel.isUsable, pane.contains(cell) {
            channel.scroll(
                up: delta > 0,
                lines: lines,
                column: UInt16(clamping: Int(cell.x - pane.minX)),
                row: UInt16(clamping: Int(cell.y - pane.minY))
            )
        } else {
            stream?.sendWheelScroll(
                up: delta > 0,
                count: lines,
                column: UInt16(clamping: Int(cell.x)),
                row: UInt16(clamping: Int(cell.y))
            )
        }
        return nil
    }

    private func forwardMouse(_ event: NSEvent, kind: UInt32, button: Int) -> NSEvent? {
        guard let cell = host?.gridCell(for: event) else { return event }
        var modifiers: UInt8 = 0
        if event.modifierFlags.contains(.shift) { modifiers |= 0x01 }
        if event.modifierFlags.contains(.control) { modifiers |= 0x02 }
        if event.modifierFlags.contains(.option) { modifiers |= 0x04 }
        if event.modifierFlags.contains(.command) { modifiers |= 0x08 }
        stream?.sendMouseEvent(
            kind: kind,
            button: button,
            column: UInt16(clamping: Int(cell.x)),
            row: UInt16(clamping: Int(cell.y)),
            modifiers: modifiers
        )
        return nil
    }
}
