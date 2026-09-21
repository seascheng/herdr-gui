import Foundation

// MARK: - endpoint.hello.v1 / endpoint.welcome.v1 (endpoint.rs port)

/// Stable endpoint protocol values (herdr ≥ 0.9.0). Generation 1.
enum EndpointConstants {
    static let generation: UInt32 = 1
    static let helloKind = "endpoint.hello.v1"
    static let welcomeKind = "endpoint.welcome.v1"
    static let snapshotCodec = "shell.snapshot.v1"
    static let surfaceCodec = "shell.surface.v1"
    static let inputCodec = "shell.input.semantic.v1"
    static let blobCodec = "shell.blob.v1"
    static let healthPingKind = "endpoint.health.ping.v1"
}

/// The JSON body of `EndpointControl{kind: "endpoint.hello.v1"}`.
struct EndpointHello: Codable, Equatable {
    var generation: UInt32
    var cellWidthPx: UInt32
    var cellHeightPx: UInt32
    var surfaceSize: ClientSurfaceSize
    var pixelMouse: Bool
    var directGraphics: Bool
    var endpointKeybindings: Bool
    var mouseCapture: Bool
    var surfaceActive: Bool
    var surfaceReuse: Bool
    var surfaceDelta: Bool
    var snapshotCodecs: [String]
    var surfaceCodecs: [String]
    var inputCodecs: [String]
    var blobCodecs: [String]

    /// herdr-gui's client posture: cell painting, semantic input, full
    /// frames + baseline patches, always-active local surface.
    static func make(cellWidth: UInt32, cellHeight: UInt32,
                     cols: UInt16, rows: UInt16) -> EndpointHello {
        EndpointHello(
            generation: EndpointConstants.generation,
            cellWidthPx: cellWidth,
            cellHeightPx: cellHeight,
            surfaceSize: ClientSurfaceSize(cols: cols, rows: rows),
            pixelMouse: false,
            directGraphics: false,
            endpointKeybindings: false,
            mouseCapture: false,
            surfaceActive: true,
            surfaceReuse: false,
            surfaceDelta: false,
            snapshotCodecs: [EndpointConstants.snapshotCodec],
            surfaceCodecs: [EndpointConstants.surfaceCodec],
            inputCodecs: [EndpointConstants.inputCodec],
            blobCodecs: [EndpointConstants.blobCodec])
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case cellWidthPx = "cell_width_px"
        case cellHeightPx = "cell_height_px"
        case surfaceSize = "surface_size"
        case endpointKeybindings = "endpoint_keybindings"
        case pixelMouse = "pixel_mouse"
        case directGraphics = "direct_graphics"
        case mouseCapture = "mouse_capture"
        case surfaceActive = "surface_active"
        case surfaceReuse = "surface_reuse"
        case surfaceDelta = "surface_delta"
        case snapshotCodecs = "snapshot_codecs"
        case surfaceCodecs = "surface_codecs"
        case inputCodecs = "input_codecs"
        case blobCodecs = "blob_codecs"
    }

    init(generation: UInt32, cellWidthPx: UInt32, cellHeightPx: UInt32,
         surfaceSize: ClientSurfaceSize, pixelMouse: Bool, directGraphics: Bool,
         endpointKeybindings: Bool, mouseCapture: Bool, surfaceActive: Bool,
         surfaceReuse: Bool, surfaceDelta: Bool, snapshotCodecs: [String],
         surfaceCodecs: [String], inputCodecs: [String], blobCodecs: [String]) {
        self.generation = generation
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.surfaceSize = surfaceSize
        self.pixelMouse = pixelMouse
        self.directGraphics = directGraphics
        self.endpointKeybindings = endpointKeybindings
        self.mouseCapture = mouseCapture
        self.surfaceActive = surfaceActive
        self.surfaceReuse = surfaceReuse
        self.surfaceDelta = surfaceDelta
        self.snapshotCodecs = snapshotCodecs
        self.surfaceCodecs = surfaceCodecs
        self.inputCodecs = inputCodecs
        self.blobCodecs = blobCodecs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(UInt32.self, forKey: .generation)
        cellWidthPx = try c.decode(UInt32.self, forKey: .cellWidthPx)
        cellHeightPx = try c.decode(UInt32.self, forKey: .cellHeightPx)
        surfaceSize = try c.decode(ClientSurfaceSize.self, forKey: .surfaceSize)
        pixelMouse = try c.decodeIfPresent(Bool.self, forKey: .pixelMouse) ?? false
        directGraphics = try c.decodeIfPresent(Bool.self, forKey: .directGraphics) ?? false
        endpointKeybindings = try c.decodeIfPresent(Bool.self, forKey: .endpointKeybindings) ?? false
        mouseCapture = try c.decodeIfPresent(Bool.self, forKey: .mouseCapture) ?? false
        surfaceActive = try c.decodeIfPresent(Bool.self, forKey: .surfaceActive) ?? true
        surfaceReuse = try c.decodeIfPresent(Bool.self, forKey: .surfaceReuse) ?? false
        surfaceDelta = try c.decodeIfPresent(Bool.self, forKey: .surfaceDelta) ?? false
        snapshotCodecs = try c.decodeIfPresent([String].self, forKey: .snapshotCodecs) ?? []
        surfaceCodecs = try c.decodeIfPresent([String].self, forKey: .surfaceCodecs) ?? []
        inputCodecs = try c.decodeIfPresent([String].self, forKey: .inputCodecs) ?? []
        blobCodecs = try c.decodeIfPresent([String].self, forKey: .blobCodecs) ?? []
    }
}


struct EndpointHandshakeErrorInfo: Codable, Equatable {
    var code: String
    var message: String
}

/// The JSON body of `EndpointControl{kind: "endpoint.welcome.v1"}`.
struct EndpointWelcome: Codable, Equatable {
    var generation: UInt32
    var serverVersion: String
    var snapshotCodec: String
    var surfaceCodec: String
    var inputCodec: String
    var blobCodec: String
    var methods: [String]
    var capabilities: [String]
    var error: EndpointHandshakeErrorInfo?

    init(generation: UInt32, serverVersion: String, snapshotCodec: String,
         surfaceCodec: String, inputCodec: String, blobCodec: String,
         methods: [String], capabilities: [String],
         error: EndpointHandshakeErrorInfo?) {
        self.generation = generation
        self.serverVersion = serverVersion
        self.snapshotCodec = snapshotCodec
        self.surfaceCodec = surfaceCodec
        self.inputCodec = inputCodec
        self.blobCodec = blobCodec
        self.methods = methods
        self.capabilities = capabilities
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case serverVersion = "server_version"
        case snapshotCodec = "snapshot_codec"
        case surfaceCodec = "surface_codec"
        case inputCodec = "input_codec"
        case blobCodec = "blob_codec"
        case methods, capabilities, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(UInt32.self, forKey: .generation)
        serverVersion = try c.decode(String.self, forKey: .serverVersion)
        snapshotCodec = try c.decode(String.self, forKey: .snapshotCodec)
        surfaceCodec = try c.decode(String.self, forKey: .surfaceCodec)
        inputCodec = try c.decode(String.self, forKey: .inputCodec)
        blobCodec = try c.decode(String.self, forKey: .blobCodec)
        methods = try c.decodeIfPresent([String].self, forKey: .methods) ?? []
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        error = try c.decodeIfPresent(EndpointHandshakeErrorInfo.self, forKey: .error)
    }

    func advertises(_ method: String) -> Bool {
        methods.contains(method)
    }
}

enum EndpointHandshakeError: Error, CustomStringConvertible {
    case serverRejected(code: String, message: String)
    case badGeneration(UInt32)
    case codecMismatch(String, String)
    case malformed(String)

    var description: String {
        switch self {
        case let .serverRejected(code, message):
            return "herdr rejected the endpoint handshake (\(code)): \(message)"
        case .badGeneration(let g):
            return "herdr speaks endpoint generation \(g); this app supports " +
                "generation \(EndpointConstants.generation). Update herdr-gui " +
                "(or herdr)."
        case .codecMismatch(let expected, let actual):
            return "endpoint codec mismatch: expected \(expected), server " +
                "offered \(actual). Update herdr-gui."
        case .malformed(let why):
            return "malformed endpoint handshake: \(why)"
        }
    }
}

/// Fail-closed welcome validation. Any deviation severs the connection with
/// a readable reason — never a silent capability guess.
func validateWelcome(_ welcome: EndpointWelcome) throws -> EndpointWelcome {
    if let error = welcome.error {
        throw EndpointHandshakeError.serverRejected(code: error.code,
                                                    message: error.message)
    }
    guard welcome.generation == EndpointConstants.generation else {
        throw EndpointHandshakeError.badGeneration(welcome.generation)
    }
    let expected: [(String, String)] = [
        ("snapshot_codec", EndpointConstants.snapshotCodec),
        ("surface_codec", EndpointConstants.surfaceCodec),
        ("input_codec", EndpointConstants.inputCodec),
        ("blob_codec", EndpointConstants.blobCodec),
    ]
    let actual = [
        "snapshot_codec": welcome.snapshotCodec,
        "surface_codec": welcome.surfaceCodec,
        "input_codec": welcome.inputCodec,
        "blob_codec": welcome.blobCodec,
    ]
    for (key, want) in expected {
        guard actual[key] == want else {
            throw EndpointHandshakeError.codecMismatch(want, actual[key] ?? "")
        }
    }
    return welcome
}
