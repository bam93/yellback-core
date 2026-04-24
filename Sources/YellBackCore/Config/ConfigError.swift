import Foundation

/// Errors thrown by `ConfigLoader` when a config cannot be produced.
///
/// Line numbers, when present, are 0-based internally and rendered as 1-based
/// in `description` (matching what users see in their text editor).
public enum ConfigError: Error, Equatable {
    /// YAML is syntactically invalid.
    case malformedYAML(message: String, line: Int?)

    /// A value is present but outside the allowed range or of the wrong type.
    case invalidValue(field: String, reason: String, line: Int?)

    /// A required top-level field is missing (per `CONFIG_SCHEMA.md`).
    case missingRequired(field: String)

    /// The config file could not be read from disk.
    case fileUnreadable(path: String, underlying: String)
}

extension ConfigError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .malformedYAML(let message, let line):
            if let line = line {
                return "malformed YAML (line \(line + 1)): \(message)"
            }
            return "malformed YAML: \(message)"

        case .invalidValue(let field, let reason, let line):
            if let line = line {
                return "invalid value at `\(field)` (line \(line + 1)): \(reason)"
            }
            return "invalid value at `\(field)`: \(reason)"

        case .missingRequired(let field):
            return "missing required field `\(field)`"

        case .fileUnreadable(let path, let underlying):
            return "could not read config file at \(path): \(underlying)"
        }
    }
}
