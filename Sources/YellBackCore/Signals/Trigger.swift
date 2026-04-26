import Foundation

/// The three detector sources YellBack surfaces to consumers.
public enum Trigger {
    case scream
    case rageType
    case deskBang
}

extension Trigger {
    /// Snake-case render matching `CONFIG_SCHEMA.md` and what users see in
    /// their YAML (`scream`, `rage_type`, `desk_bang`). Used by the CLI's
    /// `--listen` output and by the paid Mac app's UI strings.
    ///
    /// Exhaustive `switch` — adding a new `Trigger` case forces a compile
    /// error here, so we can't ship a new detector with the wrong rendering
    /// in stderr.
    public var snakeCaseName: String {
        switch self {
        case .scream: return "scream"
        case .rageType: return "rage_type"
        case .deskBang: return "desk_bang"
        }
    }
}
