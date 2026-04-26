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

    // MARK: - TriggerEvent.consoleLogLine

    /// Pin the stderr/log line format. Used by the CLI's `--listen` mode
    /// and (eventually) the paid Mac app's activity-log rendering. Tests
    /// use `contains()` rather than exact-string equality so cosmetic
    /// reformats (spacing, padding) survive without churn — but dropped
    /// fields, broken intensity formatting, or a missing primed marker
    /// fail loudly.

    func testConsoleLogLineForScreamIncludesDbfsAndIntensity() {
        let event = TriggerEvent(
            trigger: .scream,
            timestamp: Date(),
            intensity: 0.85,
            wasPrimed: false
        )
        let line = event.consoleLogLine
        XCTAssertTrue(line.contains("[trigger]"), "must carry a [trigger] tag for grep; got: \(line)")
        XCTAssertTrue(line.contains("scream"), "must name the trigger; got: \(line)")
        XCTAssertTrue(line.contains("intensity=0.85"), "must show intensity to two decimals; got: \(line)")
        // intensity=0.85 → dbfs = 0.85*60 - 60 = -9.00
        XCTAssertTrue(line.contains("dbfs=-9.00"), "must derive dbfs from intensity; got: \(line)")
        XCTAssertFalse(line.contains("(primed)"), "wasPrimed=false should not show primed marker; got: \(line)")
    }

    func testConsoleLogLineForDeskBangIncludesGForceAndIntensity() {
        let event = TriggerEvent(
            trigger: .deskBang,
            timestamp: Date(),
            intensity: 0.5,
            wasPrimed: false
        )
        let line = event.consoleLogLine
        XCTAssertTrue(line.contains("desk_bang"))
        XCTAssertTrue(line.contains("intensity=0.50"))
        // intensity=0.5 → gForce = 0.5*3 + 1 = 2.50
        XCTAssertTrue(line.contains("g_force=2.50"))
    }

    func testConsoleLogLineMarksPrimedFiringsExplicitly() {
        let event = TriggerEvent(
            trigger: .scream,
            timestamp: Date(),
            intensity: 0.6,
            wasPrimed: true
        )
        let line = event.consoleLogLine
        XCTAssertTrue(line.contains("(primed)"), "wasPrimed=true must surface to the user; got: \(line)")
    }

    func testConsoleLogLineForRageTypeUsesPlaceholderUntilDetectorImplemented() {
        let event = TriggerEvent(
            trigger: .rageType,
            timestamp: Date(),
            intensity: 0.7,
            wasPrimed: false
        )
        let line = event.consoleLogLine
        XCTAssertTrue(line.contains("rage_type"))
        XCTAssertTrue(line.contains("intensity=0.70"))
        XCTAssertTrue(line.contains("keystrokes=?"), "rage_type currently uses a placeholder until KeyboardDetector lands; got: \(line)")
    }
}
