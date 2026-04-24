import XCTest
@testable import YellBackCore

/// Boundary-value tests for every closed-interval validation rule.
///
/// `ConfigValidationTests` covers "obvious garbage is rejected." These tests
/// cover the subtler question: do the *exact* boundary values specified in
/// `CONFIG_SCHEMA.md` round-trip correctly? If `dbfs_threshold` is documented
/// as accepting `[-60, 0]`, then `-60.0` and `0.0` must both construct.
///
/// Closed-interval endpoints are tested by constructing at the boundary (must
/// succeed) and just outside it (must throw). Open endpoints (e.g.
/// `g_force_threshold > 0`) are tested by constructing just inside the open
/// bound and asserting the exact boundary throws (already in
/// `ConfigValidationTests` for those).
///
/// "Just outside" uses values like `0.01` rather than `Double.ulpOfOne`-scale
/// nudges — we want to catch off-by-ones in the `<` vs `<=` sense, not
/// floating-point edge cases that depend on the user's literal formatting.
final class ConfigBoundaryTests: XCTestCase {

    // MARK: - ScreamConfig

    func testScreamConfigAcceptsClosedIntervalBoundaries() throws {
        _ = try ScreamConfig(dbfsThreshold: 0)       // upper of [-60, 0]
        _ = try ScreamConfig(dbfsThreshold: -60)     // lower of [-60, 0]
        _ = try ScreamConfig(sustainSeconds: 60)     // upper of (, 60]
        _ = try ScreamConfig(sustainSeconds: 0)      // lower not specified; 0 is not rejected by the spec
        _ = try ScreamConfig(cooldownSeconds: 0)     // lower of [0, 60]
        _ = try ScreamConfig(cooldownSeconds: 60)    // upper of [0, 60]
    }

    func testScreamConfigRejectsJustOutsideDbfsRange() {
        XCTAssertThrowsError(try ScreamConfig(dbfsThreshold: 0.01)) { err in
            Self.assertInvalidValue(err, field: "dbfs_threshold")
        }
        XCTAssertThrowsError(try ScreamConfig(dbfsThreshold: -60.01)) { err in
            Self.assertInvalidValue(err, field: "dbfs_threshold")
        }
    }

    func testScreamConfigRejectsJustOverSixtySecondsOnEachSecondsField() {
        XCTAssertThrowsError(try ScreamConfig(sustainSeconds: 60.01)) { err in
            Self.assertInvalidValue(err, field: "sustain_seconds")
        }
        XCTAssertThrowsError(try ScreamConfig(cooldownSeconds: 60.01)) { err in
            Self.assertInvalidValue(err, field: "cooldown_seconds")
        }
    }

    func testScreamConfigRejectsJustBelowZeroCooldown() {
        XCTAssertThrowsError(try ScreamConfig(cooldownSeconds: -0.01)) { err in
            Self.assertInvalidValue(err, field: "cooldown_seconds")
        }
    }

    // MARK: - RageTypeConfig

    func testRageTypeConfigAcceptsBoundaryValues() throws {
        _ = try RageTypeConfig(keystrokesPerSecondThreshold: 1)   // lower of [1, ∞)
        _ = try RageTypeConfig(rollingWindowSeconds: 60)          // upper of (, 60]
        _ = try RageTypeConfig(cooldownSeconds: 0)
        _ = try RageTypeConfig(cooldownSeconds: 60)
    }

    // MARK: - DeskBangConfig

    func testDeskBangConfigAcceptsJustAboveZeroGForce() throws {
        // Rule is `<= 0` fails, so 0.0001 is the smallest sensible "just inside
        // the open bound" we can probe with ordinary doubles.
        _ = try DeskBangConfig(gForceThreshold: 0.0001)
        _ = try DeskBangConfig(cooldownSeconds: 0)
        _ = try DeskBangConfig(cooldownSeconds: 60)
    }

    // MARK: - PrimingConfig

    func testPrimingConfigAcceptsClosedIntervalBoundaries() throws {
        _ = try PrimingConfig(windowSeconds: 60)                   // upper of (, 60]
        _ = try PrimingConfig(thresholdMultiplier: 0.1)            // lower of [0.1, 1.0]
        _ = try PrimingConfig(thresholdMultiplier: 1.0)            // upper of [0.1, 1.0]
    }

    func testPrimingConfigRejectsJustOutsideMultiplierRange() {
        XCTAssertThrowsError(try PrimingConfig(thresholdMultiplier: 0.09)) { err in
            Self.assertInvalidValue(err, field: "threshold_multiplier")
        }
        XCTAssertThrowsError(try PrimingConfig(thresholdMultiplier: 1.01)) { err in
            Self.assertInvalidValue(err, field: "threshold_multiplier")
        }
    }

    // MARK: - AudioConfig

    func testAudioConfigAcceptsClosedIntervalBoundariesAndNil() throws {
        _ = try AudioConfig(masterVolume: 0.0)     // lower of [0, 1]
        _ = try AudioConfig(masterVolume: 1.0)     // upper of [0, 1]
        _ = try AudioConfig(masterVolume: nil)     // "follow system" sentinel
    }

    // MARK: - Helpers

    static func assertInvalidValue(
        _ error: Error,
        field expectedField: String,
        file: StaticString = #filePath,
        testLine: UInt = #line
    ) {
        guard case ConfigError.invalidValue(let field, _, _) = error else {
            XCTFail("expected ConfigError.invalidValue, got \(error)", file: file, line: testLine)
            return
        }
        XCTAssertEqual(field, expectedField, file: file, line: testLine)
    }
}
