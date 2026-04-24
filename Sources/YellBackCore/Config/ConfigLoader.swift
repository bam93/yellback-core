import Foundation
import Yams

/// Loads and validates the YAML config format documented in `CONFIG_SCHEMA.md`,
/// producing an `EngineConfig` and a list of non-fatal `ConfigWarning`s.
///
/// `ConfigLoader` is a pure YAML→struct translator. Per-field validation
/// rules live on each leaf config struct's throwing init, so programmatic
/// construction (e.g. the paid Mac app building an `EngineConfig` directly
/// from its settings UI) is validated through the same code path.
///
/// Errors thrown from struct inits carry a local field name (e.g.
/// `dbfs_threshold`) with `line: nil`. `ConfigLoader` catches these, prepends
/// the full YAML path (`triggers.scream.dbfs_threshold`), looks up the line
/// of the originating node in the Yams tree, and re-throws. Programmatic
/// callers see the bare-name, line-less original.
///
/// This type does no filesystem side-effects beyond reading the given file.
/// In particular, it does NOT create or probe `packs_directory` — that check
/// is deferred to `YellBackEngine.start()`.
public enum ConfigLoader {
    /// Result of a successful load.
    public struct LoadResult: Equatable {
        public let config: EngineConfig
        public let warnings: [ConfigWarning]

        public init(config: EngineConfig, warnings: [ConfigWarning]) {
            self.config = config
            self.warnings = warnings
        }
    }

    /// Load and validate a config from a YAML file on disk.
    public static func load(from url: URL) throws -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.fileUnreadable(
                path: url.path,
                underlying: error.localizedDescription
            )
        }
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ConfigError.malformedYAML(message: "file is not valid UTF-8", line: nil)
        }
        return try loadFromString(yaml)
    }

    /// Load and validate a config from an in-memory YAML string.
    public static func loadFromString(_ yaml: String) throws -> LoadResult {
        let rootNode: Node
        do {
            guard let node = try Yams.compose(yaml: yaml) else {
                throw ConfigError.malformedYAML(message: "config is empty", line: nil)
            }
            rootNode = node
        } catch let error as YamlError {
            throw ConfigError.malformedYAML(message: String(describing: error), line: extractLine(from: error))
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.malformedYAML(message: error.localizedDescription, line: nil)
        }

        var warnings: [ConfigWarning] = []
        let config = try parseRoot(rootNode, warnings: &warnings)
        return LoadResult(config: config, warnings: warnings)
    }

    // MARK: - Root

    private static func parseRoot(_ node: Node, warnings: inout [ConfigWarning]) throws -> EngineConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(
                field: "<root>",
                reason: "expected a mapping at the top level",
                line: node.mark?.line
            )
        }

        let required = ["triggers", "priming", "audio", "packs_directory", "logging"]
        warnUnknownKeys(in: mapping, allowed: Set(required), pathPrefix: "", warnings: &warnings)

        for key in required where mapping[key] == nil {
            throw ConfigError.missingRequired(field: key)
        }

        let triggers = try parseTriggers(mapping["triggers"]!, warnings: &warnings)
        let priming = try parsePriming(mapping["priming"]!, warnings: &warnings)
        let audio = try parseAudio(mapping["audio"]!, warnings: &warnings)
        let packsDir = try parsePacksDirectory(mapping["packs_directory"]!)
        let logging = try parseLogging(mapping["logging"]!, warnings: &warnings)

        return EngineConfig(
            triggers: triggers,
            priming: priming,
            audio: audio,
            packsDirectory: packsDir,
            logging: logging
        )
    }

    // MARK: - Triggers

    private static func parseTriggers(_ node: Node, warnings: inout [ConfigWarning]) throws -> TriggersConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(field: "triggers", reason: "expected a mapping", line: node.mark?.line)
        }

        let allowed: Set<String> = ["scream", "rage_type", "desk_bang"]
        warnUnknownKeys(in: mapping, allowed: allowed, pathPrefix: "triggers.", warnings: &warnings)

        let scream: ScreamConfig
        if let s = mapping["scream"] {
            scream = try parseScream(s, warnings: &warnings)
        } else {
            scream = try ScreamConfig(enabled: false)
        }

        let rageType: RageTypeConfig
        if let r = mapping["rage_type"] {
            rageType = try parseRageType(r, warnings: &warnings)
        } else {
            rageType = try RageTypeConfig(enabled: false)
        }

        let deskBang: DeskBangConfig
        if let d = mapping["desk_bang"] {
            deskBang = try parseDeskBang(d, warnings: &warnings)
        } else {
            deskBang = try DeskBangConfig(enabled: false)
        }

        return TriggersConfig(scream: scream, rageType: rageType, deskBang: deskBang)
    }

    private static func parseScream(_ node: Node, warnings: inout [ConfigWarning]) throws -> ScreamConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(field: "triggers.scream", reason: "expected a mapping", line: node.mark?.line)
        }
        let allowed: Set<String> = ["enabled", "dbfs_threshold", "sustain_seconds", "voice_band_filter", "cooldown_seconds"]
        warnUnknownKeys(in: mapping, allowed: allowed, pathPrefix: "triggers.scream.", warnings: &warnings)

        let enabled = try parseBool(mapping["enabled"], field: "triggers.scream.enabled", defaultValue: true)
        let dbfs = try parseDouble(mapping["dbfs_threshold"], field: "triggers.scream.dbfs_threshold", defaultValue: -20)
        let sustain = try parseDouble(mapping["sustain_seconds"], field: "triggers.scream.sustain_seconds", defaultValue: 0.3)
        let voiceBand = try parseBool(mapping["voice_band_filter"], field: "triggers.scream.voice_band_filter", defaultValue: true)
        let cooldown = try parseDouble(mapping["cooldown_seconds"], field: "triggers.scream.cooldown_seconds", defaultValue: 1.0)

        return try withEnrichedValidation(path: "triggers.scream", in: mapping) {
            try ScreamConfig(
                enabled: enabled,
                dbfsThreshold: dbfs,
                sustainSeconds: sustain,
                voiceBandFilter: voiceBand,
                cooldownSeconds: cooldown
            )
        }
    }

    private static func parseRageType(_ node: Node, warnings: inout [ConfigWarning]) throws -> RageTypeConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(field: "triggers.rage_type", reason: "expected a mapping", line: node.mark?.line)
        }
        let allowed: Set<String> = ["enabled", "keystrokes_per_second_threshold", "rolling_window_seconds", "cooldown_seconds"]
        warnUnknownKeys(in: mapping, allowed: allowed, pathPrefix: "triggers.rage_type.", warnings: &warnings)

        let enabled = try parseBool(mapping["enabled"], field: "triggers.rage_type.enabled", defaultValue: true)
        let kps = try parseInt(mapping["keystrokes_per_second_threshold"], field: "triggers.rage_type.keystrokes_per_second_threshold", defaultValue: 8)
        let window = try parseDouble(mapping["rolling_window_seconds"], field: "triggers.rage_type.rolling_window_seconds", defaultValue: 2.0)
        let cooldown = try parseDouble(mapping["cooldown_seconds"], field: "triggers.rage_type.cooldown_seconds", defaultValue: 1.5)

        return try withEnrichedValidation(path: "triggers.rage_type", in: mapping) {
            try RageTypeConfig(
                enabled: enabled,
                keystrokesPerSecondThreshold: kps,
                rollingWindowSeconds: window,
                cooldownSeconds: cooldown
            )
        }
    }

    private static func parseDeskBang(_ node: Node, warnings: inout [ConfigWarning]) throws -> DeskBangConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(field: "triggers.desk_bang", reason: "expected a mapping", line: node.mark?.line)
        }
        let allowed: Set<String> = ["enabled", "g_force_threshold", "cooldown_seconds"]
        warnUnknownKeys(in: mapping, allowed: allowed, pathPrefix: "triggers.desk_bang.", warnings: &warnings)

        let enabled = try parseBool(mapping["enabled"], field: "triggers.desk_bang.enabled", defaultValue: true)
        let g = try parseDouble(mapping["g_force_threshold"], field: "triggers.desk_bang.g_force_threshold", defaultValue: 1.5)
        let cooldown = try parseDouble(mapping["cooldown_seconds"], field: "triggers.desk_bang.cooldown_seconds", defaultValue: 0.8)

        return try withEnrichedValidation(path: "triggers.desk_bang", in: mapping) {
            try DeskBangConfig(enabled: enabled, gForceThreshold: g, cooldownSeconds: cooldown)
        }
    }

    // MARK: - Priming

    private static func parsePriming(_ node: Node, warnings: inout [ConfigWarning]) throws -> PrimingConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(field: "priming", reason: "expected a mapping", line: node.mark?.line)
        }
        let allowed: Set<String> = ["enabled", "window_seconds", "threshold_multiplier"]
        warnUnknownKeys(in: mapping, allowed: allowed, pathPrefix: "priming.", warnings: &warnings)

        let enabled = try parseBool(mapping["enabled"], field: "priming.enabled", defaultValue: true)
        let window = try parseDouble(mapping["window_seconds"], field: "priming.window_seconds", defaultValue: 5.0)
        let multiplier = try parseDouble(mapping["threshold_multiplier"], field: "priming.threshold_multiplier", defaultValue: 0.75)

        return try withEnrichedValidation(path: "priming", in: mapping) {
            try PrimingConfig(enabled: enabled, windowSeconds: window, thresholdMultiplier: multiplier)
        }
    }

    // MARK: - Audio

    private static func parseAudio(_ node: Node, warnings: inout [ConfigWarning]) throws -> AudioConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(field: "audio", reason: "expected a mapping", line: node.mark?.line)
        }
        let allowed: Set<String> = ["master_volume", "pack"]
        warnUnknownKeys(in: mapping, allowed: allowed, pathPrefix: "audio.", warnings: &warnings)

        let masterVolume = try parseOptionalDouble(
            mapping["master_volume"],
            field: "audio.master_volume",
            defaultValue: 0.8
        )
        let pack = try parseString(mapping["pack"], field: "audio.pack", defaultValue: "crowd")

        return try withEnrichedValidation(path: "audio", in: mapping) {
            try AudioConfig(masterVolume: masterVolume, pack: pack)
        }
    }

    // MARK: - Packs directory

    private static func parsePacksDirectory(_ node: Node) throws -> URL {
        guard let scalar = node.scalar else {
            throw ConfigError.invalidValue(
                field: "packs_directory",
                reason: "expected a path string",
                line: node.mark?.line
            )
        }
        let raw = scalar.string
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    // MARK: - Logging

    private static func parseLogging(_ node: Node, warnings: inout [ConfigWarning]) throws -> LoggingConfig {
        guard let mapping = node.mapping else {
            throw ConfigError.invalidValue(field: "logging", reason: "expected a mapping", line: node.mark?.line)
        }
        warnUnknownKeys(in: mapping, allowed: ["level"], pathPrefix: "logging.", warnings: &warnings)

        let levelString = try parseString(mapping["level"], field: "logging.level", defaultValue: "info")
        guard let level = LogLevel(rawValue: levelString) else {
            let allowed = LogLevel.allCases.map { $0.rawValue }.joined(separator: ", ")
            throw ConfigError.invalidValue(
                field: "logging.level",
                reason: "must be one of: \(allowed) (got '\(levelString)')",
                line: mapping["level"]?.mark?.line
            )
        }
        return LoggingConfig(level: level)
    }

    // MARK: - Struct-init error enrichment

    /// Runs a throwing struct init and, if it throws `.invalidValue` with a
    /// local field name, re-throws with the full path and the line from the
    /// originating YAML node.
    private static func withEnrichedValidation<T>(
        path: String,
        in mapping: Node.Mapping,
        _ construct: () throws -> T
    ) throws -> T {
        do {
            return try construct()
        } catch ConfigError.invalidValue(let field, let reason, _) {
            throw ConfigError.invalidValue(
                field: "\(path).\(field)",
                reason: reason,
                line: mapping[field]?.mark?.line
            )
        }
    }

    // MARK: - Scalar parsers

    private static func parseBool(_ node: Node?, field: String, defaultValue: Bool) throws -> Bool {
        guard let node = node else { return defaultValue }
        guard let scalar = node.scalar else {
            throw ConfigError.invalidValue(field: field, reason: "expected a boolean", line: node.mark?.line)
        }
        if let b = Bool.construct(from: scalar) { return b }
        throw ConfigError.invalidValue(
            field: field,
            reason: "expected a boolean (got '\(scalar.string)')",
            line: node.mark?.line
        )
    }

    private static func parseDouble(_ node: Node?, field: String, defaultValue: Double) throws -> Double {
        guard let node = node else { return defaultValue }
        guard let scalar = node.scalar else {
            throw ConfigError.invalidValue(field: field, reason: "expected a number", line: node.mark?.line)
        }
        if let d = Double.construct(from: scalar) { return d }
        throw ConfigError.invalidValue(
            field: field,
            reason: "expected a number (got '\(scalar.string)')",
            line: node.mark?.line
        )
    }

    private static func parseInt(_ node: Node?, field: String, defaultValue: Int) throws -> Int {
        guard let node = node else { return defaultValue }
        guard let scalar = node.scalar else {
            throw ConfigError.invalidValue(field: field, reason: "expected an integer", line: node.mark?.line)
        }
        if let i = Int.construct(from: scalar) { return i }
        throw ConfigError.invalidValue(
            field: field,
            reason: "expected an integer (got '\(scalar.string)')",
            line: node.mark?.line
        )
    }

    private static func parseString(_ node: Node?, field: String, defaultValue: String) throws -> String {
        guard let node = node else { return defaultValue }
        guard let scalar = node.scalar else {
            throw ConfigError.invalidValue(field: field, reason: "expected a string", line: node.mark?.line)
        }
        return scalar.string
    }

    /// Parses `Double?` where `null`/`~`/empty scalar → nil, a numeric scalar → its value,
    /// and a missing key → `defaultValue`. Anything else throws.
    private static func parseOptionalDouble(_ node: Node?, field: String, defaultValue: Double?) throws -> Double? {
        guard let node = node else { return defaultValue }
        guard let scalar = node.scalar else {
            throw ConfigError.invalidValue(field: field, reason: "expected a number or null", line: node.mark?.line)
        }
        if let d = Double.construct(from: scalar) { return d }
        let trimmed = scalar.string.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "null" || trimmed == "~" || trimmed.isEmpty {
            return nil
        }
        throw ConfigError.invalidValue(
            field: field,
            reason: "expected a number or null (got '\(scalar.string)')",
            line: node.mark?.line
        )
    }

    // MARK: - Unknown-key warnings

    private static func warnUnknownKeys(
        in mapping: Node.Mapping,
        allowed: Set<String>,
        pathPrefix: String,
        warnings: inout [ConfigWarning]
    ) {
        for (key, _) in mapping {
            guard let keyString = key.string else { continue }
            if !allowed.contains(keyString) {
                warnings.append(.unknownKey(path: "\(pathPrefix)\(keyString)", line: key.mark?.line))
            }
        }
    }

    // MARK: - Yams error line extraction

    private static func extractLine(from error: YamlError) -> Int? {
        switch error {
        case .scanner(_, _, let mark, _),
             .parser(_, _, let mark, _),
             .composer(_, _, let mark, _):
            return mark.line
        default:
            return nil
        }
    }
}
