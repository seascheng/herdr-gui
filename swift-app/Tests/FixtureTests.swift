import Foundation

/// Vendored upstream fixtures (herdrdev/herdr @ 856b64b9, Apache-2.0):
/// handshake JSON must parse into Foundation values with the contract keys.
enum FixtureTests {
    static func register() {
        let ok1 = TestRegistry.add("fixtures: hello parses with generation") {
            let data = try loadFixture("endpoint-hello-v1.json")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expect(obj?["generation"] != nil, "hello.generation missing")
            expect(obj?["surface_size"] is [String: Any], "hello.surface_size missing")
        }
        let ok2 = TestRegistry.add("fixtures: welcome parses with codecs") {
            let data = try loadFixture("endpoint-welcome-v1.json")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expect(obj?["generation"] is NSNumber, "welcome.generation missing")
            for key in ["snapshot_codec", "surface_codec",
                        "input_codec", "blob_codec"] {
                expect(obj?[key] is String, "welcome.\(key) missing")
            }
        }
        let ok3 = TestRegistry.add("fixtures: snapshot parses with projection fields") {
            let data = try loadFixture("endpoint-snapshot-v1.json")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expect(obj?["boot_id"] is String, "snapshot.boot_id missing")
            expect(obj?["revision"] != nil, "snapshot.revision missing")
            expect(obj?["workspaces"] is [Any], "snapshot.workspaces missing")
        }
        expect(ok1 && ok2 && ok3, "registration failed")
    }
}
