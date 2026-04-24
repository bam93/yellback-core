import XCTest
@testable import YellBackCore

final class ConfigLoaderTests: XCTestCase {

    // MARK: - Happy path

    func testLoadsConfigExampleYAMLFromDisk() throws {
        let result = try ConfigLoader.load(from: Self.repoConfigExampleURL)
        let c = result.config

        XCTAssertTrue(result.warnings.isEmpty, "expected no warnings, got: \(result.warnings)")

        XCTAssertTrue(c.triggers.scream.enabled)
        XCTAssertEqual(c.triggers.scream.dbfsThreshold, -20)
        XCTAssertEqual(c.triggers.scream.sustainSeconds, 0.3)
        XCTAssertTrue(c.triggers.scream.voiceBandFilter)
        XCTAssertEqual(c.triggers.scream.cooldownSeconds, 1.0)

        XCTAssertTrue(c.triggers.rageType.enabled)
        XCTAssertEqual(c.triggers.rageType.keystrokesPerSecondThreshold, 8)
        XCTAssertEqual(c.triggers.rageType.rollingWindowSeconds, 2.0)
        XCTAssertEqual(c.triggers.rageType.cooldownSeconds, 1.5)

        XCTAssertTrue(c.triggers.deskBang.enabled)
        XCTAssertEqual(c.triggers.deskBang.gForceThreshold, 1.5)
        XCTAssertEqual(c.triggers.deskBang.cooldownSeconds, 0.8)

        XCTAssertTrue(c.priming.enabled)
        XCTAssertEqual(c.priming.windowSeconds, 5.0)
        XCTAssertEqual(c.priming.thresholdMultiplier, 0.75)

        XCTAssertEqual(c.audio.masterVolume, 0.8)
        XCTAssertEqual(c.audio.pack, "crowd")

        XCTAssertTrue(c.packsDirectory.path.hasSuffix("/.config/yellback/packs"))

        XCTAssertEqual(c.logging.level, .info)
    }

    // MARK: - Defaults / omissions

    func testOmittedScreamBlockDisablesScream() throws {
        let yaml = """
        triggers:
          rage_type: { enabled: true }
          desk_bang: { enabled: true }
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
        audio: { master_volume: 0.5, pack: crowd }
        packs_directory: ~/.config/yellback/packs/
        logging: { level: info }
        """
        let result = try ConfigLoader.loadFromString(yaml)
        XCTAssertFalse(result.config.triggers.scream.enabled, "scream should be disabled when its block is omitted")
        XCTAssertTrue(result.config.triggers.rageType.enabled)
        XCTAssertTrue(result.config.triggers.deskBang.enabled)
    }

    func testOmittedFieldInsidePresentBlockGetsDefault() throws {
        let yaml = """
        triggers:
          scream: { enabled: true }
          rage_type: { enabled: true }
          desk_bang: { enabled: true }
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
        audio: { master_volume: 0.5, pack: crowd }
        packs_directory: ~/.config/yellback/packs/
        logging: { level: info }
        """
        let result = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(result.config.triggers.scream.dbfsThreshold, -20)
        XCTAssertEqual(result.config.triggers.scream.sustainSeconds, 0.3)
    }

    func testMasterVolumeNullFollowsSystem() throws {
        let yaml = Self.baseYAML(overriding: "audio:", with: """
        audio:
          master_volume: null
          pack: crowd
        """)
        let result = try ConfigLoader.loadFromString(yaml)
        XCTAssertNil(result.config.audio.masterVolume)
    }

    // MARK: - Validation failures

    func testNonNumericDbfsThresholdFails() {
        let yaml = Self.baseYAML(overriding: "triggers:", with: """
        triggers:
          scream: { enabled: true, dbfs_threshold: bunk }
          rage_type: { enabled: true }
          desk_bang: { enabled: true }
        """)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "dbfs_threshold")
        }
    }

    func testDbfsThresholdAboveZeroFails() {
        let yaml = Self.screamYAML(dbfs: 5)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "dbfs_threshold")
        }
    }

    func testDbfsThresholdBelowMinus60Fails() {
        let yaml = Self.screamYAML(dbfs: -61)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "dbfs_threshold")
        }
    }

    func testKeystrokesBelowOneFails() {
        let yaml = Self.baseYAML(overriding: "triggers:", with: """
        triggers:
          scream: { enabled: true }
          rage_type: { enabled: true, keystrokes_per_second_threshold: 0 }
          desk_bang: { enabled: true }
        """)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "keystrokes_per_second_threshold")
        }
    }

    func testGForceZeroFails() {
        XCTAssertThrowsError(try ConfigLoader.loadFromString(Self.deskBangYAML(g: 0))) { error in
            Self.assertInvalidValue(error, fieldContains: "g_force_threshold")
        }
    }

    func testGForceNegativeFails() {
        XCTAssertThrowsError(try ConfigLoader.loadFromString(Self.deskBangYAML(g: -1))) { error in
            Self.assertInvalidValue(error, fieldContains: "g_force_threshold")
        }
    }

    func testNegativeCooldownFails() {
        let yaml = Self.baseYAML(overriding: "triggers:", with: """
        triggers:
          scream: { enabled: true, cooldown_seconds: -1 }
          rage_type: { enabled: true }
          desk_bang: { enabled: true }
        """)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "cooldown_seconds")
        }
    }

    func testSecondsAboveSixtyFails() {
        let yaml = Self.baseYAML(overriding: "triggers:", with: """
        triggers:
          scream: { enabled: true, sustain_seconds: 61 }
          rage_type: { enabled: true }
          desk_bang: { enabled: true }
        """)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "sustain_seconds")
        }
    }

    func testPrimingWindowSecondsAboveSixtyFails() {
        let yaml = Self.baseYAML(overriding: "priming:", with: """
        priming: { enabled: true, window_seconds: 120, threshold_multiplier: 0.75 }
        """)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "window_seconds")
        }
    }

    func testMasterVolumeAboveOneFails() {
        XCTAssertThrowsError(try ConfigLoader.loadFromString(Self.audioYAML(volume: "1.1"))) { error in
            Self.assertInvalidValue(error, fieldContains: "master_volume")
        }
    }

    func testMasterVolumeBelowZeroFails() {
        XCTAssertThrowsError(try ConfigLoader.loadFromString(Self.audioYAML(volume: "-0.1"))) { error in
            Self.assertInvalidValue(error, fieldContains: "master_volume")
        }
    }

    func testThresholdMultiplierAboveOneFails() {
        let yaml = Self.baseYAML(overriding: "priming:", with: """
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 1.5 }
        """)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "threshold_multiplier")
        }
    }

    func testThresholdMultiplierBelowPointOneFails() {
        let yaml = Self.baseYAML(overriding: "priming:", with: """
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.05 }
        """)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "threshold_multiplier")
        }
    }

    func testInvalidLoggingLevelFails() {
        let yaml = Self.baseYAML(overriding: "logging:", with: "logging: { level: chatty }")
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            Self.assertInvalidValue(error, fieldContains: "logging.level")
        }
    }

    // MARK: - Structural errors

    func testMissingRequiredTopLevelKeyFails() {
        let yaml = """
        triggers: { scream: { enabled: true } }
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
        audio: { master_volume: 0.5, pack: crowd }
        logging: { level: info }
        """
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            guard case ConfigError.missingRequired(let field) = error else {
                XCTFail("expected .missingRequired, got \(error)")
                return
            }
            XCTAssertEqual(field, "packs_directory")
        }
    }

    func testMalformedYAMLReportsLineNumber() {
        let yaml = """
        triggers:
          scream: { enabled: true
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
        """
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            guard case ConfigError.malformedYAML(_, let line) = error else {
                XCTFail("expected .malformedYAML, got \(error)")
                return
            }
            XCTAssertNotNil(line, "malformed YAML should carry a line number")
        }
    }

    func testEmptyConfigFails() {
        XCTAssertThrowsError(try ConfigLoader.loadFromString("")) { error in
            guard case ConfigError.malformedYAML = error else {
                XCTFail("expected .malformedYAML for empty input, got \(error)")
                return
            }
        }
    }

    // MARK: - Warnings

    func testUnknownTopLevelKeyWarnsButLoads() throws {
        let yaml = Self.validYAML + "\nfuture_knob: 42\n"
        let result = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(result.warnings.count, 1)
        if case .unknownKey(let path, _) = result.warnings[0] {
            XCTAssertEqual(path, "future_knob")
        } else {
            XCTFail("expected unknownKey warning, got \(result.warnings[0])")
        }
    }

    func testUnknownSubBlockKeyWarnsButLoads() throws {
        let yaml = Self.baseYAML(overriding: "triggers:", with: """
        triggers:
          scream: { enabled: true, unknown_tweak: 0.5 }
          rage_type: { enabled: true }
          desk_bang: { enabled: true }
        """)
        let result = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(result.warnings.count, 1)
        if case .unknownKey(let path, _) = result.warnings[0] {
            XCTAssertEqual(path, "triggers.scream.unknown_tweak")
        } else {
            XCTFail("expected unknownKey warning, got \(result.warnings[0])")
        }
    }

    // MARK: - Helpers

    /// Resolves repo-root-relative to `config.example.yaml` via `#filePath`.
    /// Layout: repoRoot/Tests/YellBackCoreTests/<this file>
    static var repoConfigExampleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/YellBackCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("config.example.yaml")
    }

    /// A minimal valid YAML covering every required top-level key.
    ///
    /// Intentionally one-line-per-top-level-key (flow mappings everywhere) so
    /// `baseYAML(overriding:, with:)` can splice one line cleanly without
    /// producing duplicate keys further down.
    static let validYAML: String = """
    triggers: { scream: { enabled: true }, rage_type: { enabled: true }, desk_bang: { enabled: true } }
    priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
    audio: { master_volume: 0.5, pack: crowd }
    packs_directory: ~/.config/yellback/packs/
    logging: { level: info }
    """

    /// Returns `validYAML` with the block whose first line matches `blockHeader`
    /// replaced by the given replacement text. Quick surgery for focused tests.
    static func baseYAML(overriding blockHeader: String, with replacement: String) -> String {
        var lines = validYAML.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.hasPrefix(blockHeader) }) else {
            fatalError("test helper bug: no line starts with '\(blockHeader)' in validYAML")
        }
        lines[idx] = replacement
        return lines.joined(separator: "\n")
    }

    static func screamYAML(dbfs: Double) -> String {
        baseYAML(overriding: "triggers:", with: """
        triggers:
          scream: { enabled: true, dbfs_threshold: \(dbfs) }
          rage_type: { enabled: true }
          desk_bang: { enabled: true }
        """)
    }

    static func deskBangYAML(g: Double) -> String {
        baseYAML(overriding: "triggers:", with: """
        triggers:
          scream: { enabled: true }
          rage_type: { enabled: true }
          desk_bang: { enabled: true, g_force_threshold: \(g) }
        """)
    }

    static func audioYAML(volume: String) -> String {
        baseYAML(overriding: "audio:", with: "audio: { master_volume: \(volume), pack: crowd }")
    }

    static func assertInvalidValue(
        _ error: Error,
        fieldContains substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case ConfigError.invalidValue(let field, _, _) = error else {
            XCTFail("expected ConfigError.invalidValue, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            field.contains(substring),
            "expected field to contain '\(substring)', got '\(field)'",
            file: file,
            line: line
        )
    }
}
