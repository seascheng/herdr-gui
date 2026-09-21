import Foundation

// MARK: - app-facing endpoint client with reconnect policy
//
// EndpointSession is one-shot by contract (no replay). This handle owns the
// reconnect lifecycle: bounded backoff, stability reset, and permanent
// failure for handshake rejections (unsupported generation/codec) which no
// retry can fix.

final class EndpointClient {
    enum State: Equatable {
        case connecting
        case connected
        case disconnected  // transient; reconnecting
        case failed(String)  // permanent; needs user action (e.g. upgrade herdr)
    }

    let socketPath: String
    private let cellWidth: UInt32
    private let cellHeight: UInt32

    private var session: EndpointSession?
    private var reconnectWork: DispatchWorkItem?
    private var backoff: TimeInterval = 0.5
    private var stableSince: Date?
    private var stopped = false
    private(set) var state: State = .disconnected {
        didSet { onState?(state) }
    }

    // Main-thread callbacks.
    var onSnapshot: ((ClientShellSnapshot) -> Void)?
    var onSurface: ((PaneSurfaceFrame) -> Void)?
    var onNotification: ((SemanticNotification) -> Void)?
    var onClipboard: ((String) -> Void)?
    var onTitle: ((String?) -> Void)?
    var onState: ((State) -> Void)?

    init(socketPath: String, cellWidth: UInt32, cellHeight: UInt32) {
        self.socketPath = socketPath
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    // MARK: Lifecycle

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        reconnectWork?.cancel()
        reconnectWork = nil
        session?.stop()
        session = nil
        state = .disconnected
    }

    private func connect() {
        guard !stopped else { return }
        state = .connecting
        let session = EndpointSession(socketPath: socketPath,
                                      cellWidth: cellWidth,
                                      cellHeight: cellHeight)
        self.session = session
        wire(session)
        session.start()
    }

    private func wire(_ session: EndpointSession) {
        session.onWelcome = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.stableSince = Date()
                self.backoff = 0.5
                self.state = .connected
            }
        }
        session.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.onSnapshot?(snapshot)
            }
        }
        session.onSurface = { [weak self] surface in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.onSurface?(surface)
            }
        }
        session.onNotification = { [weak self] note in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.onNotification?(note)
            }
        }
        session.onClipboard = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.onClipboard?(data)
            }
        }
        session.onTitle = { [weak self] title in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.onTitle?(title)
            }
        }
        session.onDisconnected = { [weak self] reason in
            DispatchQueue.main.async {
                self?.handleDisconnect(reason: reason, from: session)
            }
        }
    }

    private func handleDisconnect(reason: String, from session: EndpointSession) {
        guard !stopped, self.session === session else { return }
        self.session = nil
        // Handshake rejections (generation/codec/welcome errors) are
        // permanent: retrying cannot change what the server speaks.
        if reason.hasPrefix("handshake failed") {
            state = .failed(reason)
            return
        }
        // A connection that stayed up ≥30s resets the backoff ladder.
        if let stableSince, Date().timeIntervalSince(stableSince) >= 30 {
            backoff = 0.5
        }
        stableSince = nil
        state = .disconnected
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(backoff * 2, 30)
    }

    // MARK: Forwarded commands (no-ops while disconnected)

    func sendPaneInput(paneId: String, events: [ClientPaneInputEvent]) {
        session?.sendPaneInput(paneId: paneId, events: events)
    }

    func sendPopupInput(terminalId: String, events: [ClientPaneInputEvent]) {
        session?.sendPopupInput(terminalId: terminalId, events: events)
    }

    func resize(cellWidth: UInt32, cellHeight: UInt32, cols: UInt16, rows: UInt16) {
        session?.resize(cellWidth: cellWidth, cellHeight: cellHeight,
                        cols: cols, rows: rows)
    }

    /// API request; completion on main with the parsed object or nil.
    func request(method: String, params: [String: Any] = [:],
                 completion: (([String: Any]?) -> Void)? = nil) {
        guard let session else {
            completion.map { block in DispatchQueue.main.async { block(nil) } }
            return
        }
        session.request(method: method, params: params) { object in
            DispatchQueue.main.async { completion?(object) }
        }
    }
}
