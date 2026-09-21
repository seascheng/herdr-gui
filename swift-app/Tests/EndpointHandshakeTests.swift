import Foundation

/// Handshake JSON round-trips (upstream fixtures) and the fail-closed
/// welcome validation matrix.
enum EndpointHandshakeTests {
    static func register() {
        let ok1 = TestRegistry.add("handshake: fixture hello decodes and re-encodes") {
            let data = try loadFixture("endpoint-hello-v1.json")
            let hello = try JSONDecoder().decode(EndpointHello.self, from: data)
            expectEq(hello.generation, 1, "generation")
            expectEq(hello.cellWidthPx, 8, "cell width")
            expectEq(hello.surfaceSize.cols, 80, "cols")
            expectEq(hello.pixelMouse, true, "pixel mouse")
            expectEq(hello.snapshotCodecs, ["shell.snapshot.v1"], "snapshot codecs")
            let hello2 = EndpointHello.make(cellWidth: 10, cellHeight: 20, cols: 100, rows: 30)
            expectEq(hello2.generation, 1, "make generation")
            expectEq(hello2.pixelMouse, false, "make pixel mouse")
            expectEq(hello2.directGraphics, false, "make direct graphics")
            expectEq(hello2.endpointKeybindings, false, "make endpoint keybindings")
            expectEq(hello2.mouseCapture, false, "make mouse capture")
            expectEq(hello2.surfaceActive, true, "make surface active")
            expectEq(hello2.surfaceReuse, false, "make surface reuse")
            expectEq(hello2.surfaceDelta, false, "make surface delta")
            expectEq(hello2.surfaceCodecs, ["shell.surface.v1"], "make surface codecs")
            expectEq(hello2.blobCodecs, ["shell.blob.v1"], "make blob codecs")
            expectEq(hello2.inputCodecs, ["shell.input.semantic.v1"], "make input codecs")
        }
        let ok2 = TestRegistry.add("handshake: fixture welcome validates") {
            let data = try loadFixture("endpoint-welcome-v1.json")
            let welcome = try JSONDecoder().decode(EndpointWelcome.self, from: data)
            expectEq(welcome.serverVersion, "0.8.2", "server version")
            expectEq(welcome.methods, ["pane.focus"], "methods")
            _ = try validateWelcome(welcome)  // throws on any violation
        }
        let ok3 = TestRegistry.add("handshake: welcome error fails closed") {
            var welcome = Self.goodWelcome()
            welcome.error = EndpointHandshakeErrorInfo(code: "unsupported_generation",
                                                       message: "nope")
            expectThrows({ try validateWelcome(welcome) }, "error present")
        }
        let ok4 = TestRegistry.add("handshake: generation mismatch rejected") {
            var welcome = Self.goodWelcome()
            welcome.generation = 2
            expectThrows({ try validateWelcome(welcome) }, "generation 2")
            welcome.generation = 0
            expectThrows({ try validateWelcome(welcome) }, "generation 0")
        }
        let ok5 = TestRegistry.add("handshake: codec mismatch rejected per codec") {
            for (key, bad) in [("snapshot_codec", "shell.snapshot.v2"),
                               ("surface_codec", "shell.surface.v2"),
                               ("input_codec", "x"),
                               ("blob_codec", "")] {
                var welcome = Self.goodWelcome()
                switch key {
                case "snapshot_codec": welcome.snapshotCodec = bad
                case "surface_codec": welcome.surfaceCodec = bad
                case "input_codec": welcome.inputCodec = bad
                default: welcome.blobCodec = bad
                }
                expectThrows({ try validateWelcome(welcome) }, "codec \(key)")
            }
        }
        expect(ok1 && ok2 && ok3 && ok4 && ok5, "registration")
    }

    static func goodWelcome() -> EndpointWelcome {
        EndpointWelcome(
            generation: 1,
            serverVersion: "0.9.1",
            snapshotCodec: "shell.snapshot.v1",
            surfaceCodec: "shell.surface.v1",
            inputCodec: "shell.input.semantic.v1",
            blobCodec: "shell.blob.v1",
            methods: ["tab.focus", "workspace.create", "pane.focus"],
            capabilities: ["surface_interest"],
            error: nil)
    }
}
