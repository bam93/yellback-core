import Foundation

/// Shared validation primitives used by throwing inits on config leaf types.
///
/// Each helper throws `ConfigError.invalidValue` with `line: nil` — the
/// struct init has no way to know which line of YAML (if any) produced its
/// input. `ConfigLoader` catches these errors and enriches them with the
/// line from the originating Yams `Node`.
///
/// Field names are the snake_case spellings from `CONFIG_SCHEMA.md`.
enum ConfigValidation {
    /// Rule: `dbfs_threshold` must fall in the closed interval [-60, 0].
    static func checkDbfs(_ value: Double, field: String) throws {
        if value > 0 || value < -60 {
            throw ConfigError.invalidValue(
                field: field,
                reason: "must be in [-60, 0] (got \(value))",
                line: nil
            )
        }
    }

    /// Rule: any `_seconds` field must be <= 60 (values above are treated as
    /// user error rather than deliberate config).
    static func checkSecondsUpperBound(_ value: Double, field: String) throws {
        if value > 60 {
            throw ConfigError.invalidValue(
                field: field,
                reason: "must be <= 60 seconds (got \(value))",
                line: nil
            )
        }
    }

    /// Rule combined: any `cooldown_seconds` must be >= 0, AND the general
    /// `_seconds <= 60` upper bound.
    static func checkCooldown(_ value: Double, field: String) throws {
        if value < 0 {
            throw ConfigError.invalidValue(
                field: field,
                reason: "must be >= 0 (got \(value))",
                line: nil
            )
        }
        try checkSecondsUpperBound(value, field: field)
    }
}
