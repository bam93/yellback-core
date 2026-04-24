import XCTest
@testable import YellBackCore

/// Exercises validation on the *programmatic* construction path — the paid
/// Mac app, or any other caller, building config values in Swift rather than
/// via YAML.
///
/// The YAML path is covered exhaustively in `ConfigLoaderTests`. These tests
/// only need to prove that each rule actually runs from the struct init, that
/// errors carry the snake_case field names promised by `EngineConfig.swift`'s
/// doc comment, and that errors from the struct path carry `line: nil`
/// (since there is no YAML to point at).
final class ConfigValidationTests: XCTestCase {

    // MARK: - ScreamConfig

    func testScreamConfigRejectsDbfsAboveZero() {
        XCTAssertThrowsError(try ScreamConfig(dbfsThreshold: 5)) { error in
            Self.assertInvalidValue(error, field: "dbfs_threshold", lineIsNil: true)
        }
    }

    func testScreamConfigRejectsDbfsBelowMinus60() {
        XCTAssertThrowsError(try ScreamConfig(dbfsThreshold: -61)) { error in
            Self.assertInvalidValue(error, field: "dbfs_threshold", lineIsNil: true)
        }
    }

    func testScreamConfigRejectsSustainAboveSixty() {
        XCTAssertThrowsError(try ScreamConfig(sustainSeconds: 61)) { error in
            Self.assertInvalidValue(error, field: "sustain_seconds", lineIsNil: true)
        }
    }

    func testScreamConfigRejectsNegativeCooldown() {
        XCTAssertThrowsError(try ScreamConfig(cooldownSeconds: -1)) { error in
            Self.assertInvalidValue(error, field: "cooldown_seconds", lineIsNil: true)
        }
    }

    func testScreamConfigAcceptsDefaults() throws {
        let c = try ScreamConfig()
        XCTAssertEqual(c, .default)
    }

    // MARK: - RageTypeConfig

    func testRageTypeConfigRejectsKeystrokesBelowOne() {
        XCTAssertThrowsError(try RageTypeConfig(keystrokesPerSecondThreshold: 0)) { error in
            Self.assertInvalidValue(error, field: "keystrokes_per_second_threshold", lineIsNil: true)
        }
    }

    // MARK: - DeskBangConfig

    func testDeskBangConfigRejectsZeroGForce() {
        XCTAssertThrowsError(try DeskBangConfig(gForceThreshold: 0)) { error in
            Self.assertInvalidValue(error, field: "g_force_threshold", lineIsNil: true)
        }
    }

    func testDeskBangConfigRejectsNegativeGForce() {
        XCTAssertThrowsError(try DeskBangConfig(gForceThreshold: -1)) { error in
            Self.assertInvalidValue(error, field: "g_force_threshold", lineIsNil: true)
        }
    }

    // MARK: - PrimingConfig

    func testPrimingConfigRejectsMultiplierAboveOne() {
        XCTAssertThrowsError(try PrimingConfig(thresholdMultiplier: 1.5)) { error in
            Self.assertInvalidValue(error, field: "threshold_multiplier", lineIsNil: true)
        }
    }

    func testPrimingConfigRejectsMultiplierBelowPointOne() {
        XCTAssertThrowsError(try PrimingConfig(thresholdMultiplier: 0.05)) { error in
            Self.assertInvalidValue(error, field: "threshold_multiplier", lineIsNil: true)
        }
    }

    func testPrimingConfigRejectsWindowAboveSixty() {
        XCTAssertThrowsError(try PrimingConfig(windowSeconds: 120)) { error in
            Self.assertInvalidValue(error, field: "window_seconds", lineIsNil: true)
        }
    }

    // MARK: - AudioConfig

    func testAudioConfigRejectsVolumeAboveOne() {
        XCTAssertThrowsError(try AudioConfig(masterVolume: 1.1)) { error in
            Self.assertInvalidValue(error, field: "master_volume", lineIsNil: true)
        }
    }

    func testAudioConfigRejectsVolumeBelowZero() {
        XCTAssertThrowsError(try AudioConfig(masterVolume: -0.1)) { error in
            Self.assertInvalidValue(error, field: "master_volume", lineIsNil: true)
        }
    }

    func testAudioConfigAcceptsNullVolume() throws {
        let c = try AudioConfig(masterVolume: nil)
        XCTAssertNil(c.masterVolume)
    }

    // MARK: - YAML path still enriches with path + line

    /// Double-checks the contract the refactor depends on: when a leaf struct
    /// rejects a value during a YAML load, `ConfigLoader` enriches the error
    /// with the full path and the line number from the YAML source. Without
    /// this, the Session-2 YAML-path UX (file editors pointing at line N)
    /// would silently regress to "just a field name."
    func testYAMLPathEnrichesValidationErrorsWithLineAndFullPath() {
        let yaml = """
        triggers: { scream: { enabled: true, dbfs_threshold: 99 }, rage_type: { enabled: true }, desk_bang: { enabled: true } }
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
        audio: { master_volume: 0.5, pack: crowd }
        packs_directory: ~/.config/yellback/packs/
        logging: { level: info }
        """
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            guard case ConfigError.invalidValue(let field, _, let line) = error else {
                XCTFail("expected .invalidValue, got \(error)")
                return
            }
            XCTAssertEqual(field, "triggers.scream.dbfs_threshold",
                           "YAML path should report the full dotted field path")
            XCTAssertNotNil(line,
                            "YAML path should carry a line number from the Yams node mark")
        }
    }

    // MARK: - Helpers

    static func assertInvalidValue(
        _ error: Error,
        field expectedField: String,
        lineIsNil: Bool,
        file: StaticString = #filePath,
        testLine: UInt = #line
    ) {
        guard case ConfigError.invalidValue(let field, _, let line) = error else {
            XCTFail("expected ConfigError.invalidValue, got \(error)", file: file, line: testLine)
            return
        }
        XCTAssertEqual(field, expectedField, file: file, line: testLine)
        if lineIsNil {
            XCTAssertNil(line, "programmatic-path errors should carry no line number", file: file, line: testLine)
        }
    }
}
