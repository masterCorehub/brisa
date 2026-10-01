import Foundation

/// A small dependency-free test runner, so tests build with plain `swiftc` like the app does.
struct TestCase {
    let name: String
    let run: () throws -> Void
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition else { throw TestFailure(description: "\(file):\(line) expectation failed. \(message())") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected else { throw TestFailure(description: "\(file):\(line) expected \(expected), got \(actual)") }
}

func expectNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws {
    guard value == nil else { throw TestFailure(description: "\(file):\(line) expected nil, got \(value!)") }
}

func unwrap<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line) unexpected nil") }
    return value
}

@main
enum TestRunner {
    static func main() {
        let tests = MixSharingTests.all + RoutineScheduleTests.all + SoundSynthesisTests.all + ModeTests.all + BreakActivityTests.all
        var failures = 0
        for test in tests {
            do {
                try test.run()
                print("✓ \(test.name)")
            } catch {
                failures += 1
                print("✗ \(test.name): \(error)")
            }
        }
        print("\n\(tests.count - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
