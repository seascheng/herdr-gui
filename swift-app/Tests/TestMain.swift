import Foundation

// MARK: - Minimal CLI test runner (no XCTest; swiftc-compiled like build.sh)

var passed = 0
var failures = 0

func expect(_ cond: Bool, _ msg: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    if cond { passed += 1 } else {
        failures += 1
        print("FAIL \(file):\(line) \(msg())")
    }
}

func expectEq<T: Equatable>(_ a: T, _ b: T, _ label: String = "",
                            file: StaticString = #fileID, line: UInt = #line) {
    if a == b { passed += 1 } else {
        failures += 1
        print("FAIL \(file):\(line) \(label): \(a) != \(b)")
    }
}

func expectThrows<T>(_ body: () throws -> T, _ label: String = "",
                     file: StaticString = #fileID, line: UInt = #line) {
    do {
        _ = try body()
        failures += 1
        print("FAIL \(file):\(line) \(label): expected throw, returned normally")
    } catch {
        passed += 1
    }
}

func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try Data(contentsOf: url)
}

typealias TestFn = () throws -> Void

enum TestRegistry {
    static var tests: [(String, TestFn)] = []
    @discardableResult
    static func add(_ name: String, _ fn: @escaping TestFn) -> Bool {
        tests.append((name, fn))
        return true
    }
}

@main
enum TestRunner {
    static func main() {
        // One register call per test file; keep alphabetized as files land.
        FixtureTests.register()
        for (name, fn) in TestRegistry.tests {
            do { try fn() } catch {
                failures += 1
                print("FAIL \(name): threw \(error)")
            }
        }
        print("---")
        print("\(passed) passed, \(failures) failed, \(TestRegistry.tests.count) tests")
        exit(failures == 0 ? 0 : 1)
    }
}
