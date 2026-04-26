import XCTest
@testable import YellBackCore

/// Tests for the `Trigger` enum and its rendering extensions.
final class TriggerTests: XCTestCase {

    /// Locks the snake_case rendering used by the CLI's `--listen` output
    /// (and any future paid-app surface that mirrors it). The doc comment
    /// on `Trigger.snakeCaseName` claims an exhaustive switch — adding a
    /// `Trigger` case forces a compile error there. This test additionally
    /// pins the actual strings, so a casual rename in the switch fails
    /// loudly instead of silently re-styling user-facing output.
    func testSnakeCaseNameRendersAllCasesCorrectly() {
        XCTAssertEqual(Trigger.scream.snakeCaseName, "scream")
        XCTAssertEqual(Trigger.rageType.snakeCaseName, "rage_type")
        XCTAssertEqual(Trigger.deskBang.snakeCaseName, "desk_bang")
    }
}
