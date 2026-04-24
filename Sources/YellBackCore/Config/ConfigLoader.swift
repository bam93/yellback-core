import Foundation
import Yams

/// Loads and validates the YAML config format documented in
/// `CONFIG_SCHEMA.md`, producing an `EngineConfig`.
///
/// Validation failures throw with a clear, human-readable message and
/// (where Yams provides it) a line number. Partial configs are never
/// applied — either the file is fully valid or loading fails.
enum ConfigLoader {}
