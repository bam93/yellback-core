import Foundation

/// Non-fatal diagnostic from `ConfigLoader`. Returned alongside the parsed
/// config; the consumer decides how to render (CLI prints to stderr, paid app
/// surfaces in a settings-panel banner).
public enum ConfigWarning: Equatable {
    /// A key that the current schema does not recognise. Ignored during
    /// parsing — present so older binaries tolerate forward-compatible config
    /// files produced by newer versions.
    case unknownKey(path: String, line: Int?)
}

extension ConfigWarning: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownKey(let path, let line):
            if let line = line {
                return "unknown key `\(path)` (line \(line + 1)) — ignored"
            }
            return "unknown key `\(path)` — ignored"
        }
    }
}
