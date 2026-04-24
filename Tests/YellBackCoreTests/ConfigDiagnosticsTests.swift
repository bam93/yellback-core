import XCTest
@testable import YellBackCore

/// Tests for `ConfigError` and `ConfigWarning` diagnostic behavior:
/// line-number accuracy on the YAML path, and `CustomStringConvertible`
/// rendering on both paths.
///
/// Line-number accuracy is the architectural justification for walking the
/// Yams `Node` tree manually instead of using `YAMLDecoder` + `Codable`.
/// Locking exact line numbers in tests means a future Yams upgrade or loader
/// refactor can't silently regress the UX that justified the extra code.
///
/// Yams `Mark.line` is 1-based — matching what a text editor shows the user.
/// `ConfigError`/`ConfigWarning` stores and renders that value as-is, with no
/// offset applied in `description`. (A prior iteration of this code applied
/// `+ 1` under the mistaken assumption that Yams was 0-based; these tests
/// catch that class of regression.)
///
/// Description format is asserted via `contains()` on key substrings rather
/// than full-string equality. That survives cosmetic rewording (e.g. " — "
/// → " – ") but still catches real regressions: dropped line numbers, missing
/// field names, off-by-one rendering drift.
final class ConfigDiagnosticsTests: XCTestCase {

    // MARK: - Line-number accuracy (YAML path)

    func testValidationErrorReportsExactLineOfBadValue() {
        // Lines (1-indexed, as Yams reports):
        //   1: triggers:
        //   2:   scream:
        //   3:     dbfs_threshold: 99   ← the bad value
        //   4: priming: { ... }
        //   ...
        let yaml = """
        triggers:
          scream:
            dbfs_threshold: 99
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
        audio: { master_volume: 0.5, pack: crowd }
        packs_directory: ~/.config/yellback/packs/
        logging: { level: info }
        """
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            guard case ConfigError.invalidValue(_, _, let line) = error else {
                XCTFail("expected .invalidValue, got \(error)")
                return
            }
            XCTAssertEqual(line, 3, "the bad dbfs_threshold scalar is on 1-indexed line 3")
        }
    }

    func testUnknownKeyWarningReportsExactLineOfTheKey() throws {
        // Lines (1-indexed):
        //   1: triggers: ...
        //   2: priming: ...
        //   3: audio: ...
        //   4: packs_directory: ...
        //   5: logging: ...
        //   6: future_knob: 42     ← the unknown key
        let yaml = """
        triggers: { scream: { enabled: true }, rage_type: { enabled: true }, desk_bang: { enabled: true } }
        priming: { enabled: true, window_seconds: 5, threshold_multiplier: 0.75 }
        audio: { master_volume: 0.5, pack: crowd }
        packs_directory: ~/.config/yellback/packs/
        logging: { level: info }
        future_knob: 42
        """
        let result = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(result.warnings.count, 1)
        guard case .unknownKey(_, let line) = result.warnings[0] else {
            XCTFail("expected .unknownKey warning, got \(result.warnings[0])")
            return
        }
        XCTAssertEqual(line, 6, "future_knob: is on 1-indexed line 6")
    }

    func testMalformedYAMLReportsANonNilLineNumberNearTheProblem() {
        // Unterminated flow mapping. Yams typically reports the position
        // where it gave up parsing, which can be at or just past the line
        // containing the syntax error. We don't pin an exact value
        // (Yams-internal) but do bound it within the fixture's scope so a
        // regression that loses line info entirely (or returns gibberish
        // like line 0 or the last line of an unrelated file) is caught.
        let yaml = """
        triggers:
          scream: { enabled: true
        """
        XCTAssertThrowsError(try ConfigLoader.loadFromString(yaml)) { error in
            guard case ConfigError.malformedYAML(_, let line) = error else {
                XCTFail("expected .malformedYAML, got \(error)")
                return
            }
            guard let line = line else {
                XCTFail("expected a non-nil line number for malformed YAML")
                return
            }
            // Fixture is 2 source lines; Yams may report either line 2
            // (where the flow scalar starts) or line 3 (end-of-input
            // position after a newline). Anything outside [1, 3] is a bug.
            XCTAssertGreaterThanOrEqual(line, 1, "Yams reports 1-indexed lines")
            XCTAssertLessThanOrEqual(line, 3, "line should be within the fixture's extent")
        }
    }

    // MARK: - ConfigError.description

    func testInvalidValueDescriptionFormat() {
        let withLine: ConfigError = .invalidValue(
            field: "triggers.scream.dbfs_threshold",
            reason: "must be in [-60, 0] (got 5.0)",
            line: 4
        )
        let withLineStr = String(describing: withLine)
        XCTAssertTrue(withLineStr.contains("triggers.scream.dbfs_threshold"),
                      "description should name the field; got: \(withLineStr)")
        XCTAssertTrue(withLineStr.contains("must be in [-60, 0] (got 5.0)"),
                      "description should include the reason; got: \(withLineStr)")
        XCTAssertTrue(withLineStr.contains("line 4"),
                      "Yams lines are 1-based — line:4 should render as 'line 4'; got: \(withLineStr)")
        XCTAssertFalse(withLineStr.contains("line 5"),
                       "description must not silently add +1 to the stored line; got: \(withLineStr)")

        let withoutLine: ConfigError = .invalidValue(
            field: "dbfs_threshold",
            reason: "must be in [-60, 0] (got 5.0)",
            line: nil
        )
        let withoutLineStr = String(describing: withoutLine)
        XCTAssertTrue(withoutLineStr.contains("dbfs_threshold"))
        XCTAssertTrue(withoutLineStr.contains("must be in [-60, 0] (got 5.0)"))
        XCTAssertFalse(withoutLineStr.contains("line "),
                       "description should omit '(line …)' when line is nil; got: \(withoutLineStr)")
    }

    func testMalformedYAMLDescriptionFormat() {
        let withLine: ConfigError = .malformedYAML(message: "expected ':'", line: 2)
        let withLineStr = String(describing: withLine)
        XCTAssertTrue(withLineStr.contains("expected ':'"))
        XCTAssertTrue(withLineStr.contains("line 2"),
                      "Yams lines are 1-based — line:2 should render as 'line 2'; got: \(withLineStr)")
        XCTAssertTrue(withLineStr.lowercased().contains("malformed yaml"),
                      "should identify the failure as a YAML problem; got: \(withLineStr)")

        let withoutLine: ConfigError = .malformedYAML(message: "file is empty", line: nil)
        let withoutLineStr = String(describing: withoutLine)
        XCTAssertTrue(withoutLineStr.contains("file is empty"))
        XCTAssertFalse(withoutLineStr.contains("line "),
                       "description should omit '(line …)' when line is nil; got: \(withoutLineStr)")
    }

    func testMissingRequiredDescriptionFormat() {
        let error: ConfigError = .missingRequired(field: "packs_directory")
        let str = String(describing: error)
        XCTAssertTrue(str.contains("packs_directory"),
                      "description should name the missing field; got: \(str)")
        XCTAssertTrue(str.lowercased().contains("missing") || str.lowercased().contains("required"),
                      "description should indicate the field is required; got: \(str)")
    }

    func testFileUnreadableDescriptionFormat() {
        let error: ConfigError = .fileUnreadable(
            path: "/etc/yellback/config.yaml",
            underlying: "Permission denied"
        )
        let str = String(describing: error)
        XCTAssertTrue(str.contains("/etc/yellback/config.yaml"),
                      "description should include the path; got: \(str)")
        XCTAssertTrue(str.contains("Permission denied"),
                      "description should include the underlying OS message; got: \(str)")
    }

    // MARK: - ConfigWarning.description

    func testUnknownKeyWarningDescriptionFormat() {
        let withLine: ConfigWarning = .unknownKey(path: "triggers.scream.future_knob", line: 7)
        let withLineStr = String(describing: withLine)
        XCTAssertTrue(withLineStr.contains("triggers.scream.future_knob"),
                      "warning should name the unknown key path; got: \(withLineStr)")
        XCTAssertTrue(withLineStr.contains("line 7"),
                      "Yams lines are 1-based — line:7 should render as 'line 7'; got: \(withLineStr)")
        XCTAssertTrue(withLineStr.lowercased().contains("ignored") || withLineStr.lowercased().contains("unknown"),
                      "warning should communicate that the key is being ignored; got: \(withLineStr)")

        let withoutLine: ConfigWarning = .unknownKey(path: "future_knob", line: nil)
        let withoutLineStr = String(describing: withoutLine)
        XCTAssertTrue(withoutLineStr.contains("future_knob"))
        XCTAssertFalse(withoutLineStr.contains("line "),
                       "should omit '(line …)' when line is nil; got: \(withoutLineStr)")
    }
}
