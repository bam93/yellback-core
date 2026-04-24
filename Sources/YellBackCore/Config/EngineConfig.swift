import Foundation

/// Root config consumed by `YellBackEngine`. Produced by `ConfigLoader` from
/// a YAML file matching `CONFIG_SCHEMA.md`, or constructed programmatically
/// by consumers that already hold typed values (notably the paid Mac app's
/// settings UI).
///
/// `EngineConfig` itself has no validation rules — the rules live on each
/// leaf struct's init, which throws `ConfigError.invalidValue` on any
/// violation. Aggregator types (`EngineConfig`, `TriggersConfig`,
/// `LoggingConfig`) are therefore non-throwing: if every leaf is valid,
/// the aggregate is valid.
///
/// Every field uses a documented default sourced from `config.example.yaml`,
/// so `EngineConfig()` returns a fully-usable default without a file.
public struct EngineConfig: Equatable {
    public let triggers: TriggersConfig
    public let priming: PrimingConfig
    public let audio: AudioConfig
    public let packsDirectory: URL
    public let logging: LoggingConfig

    public init(
        triggers: TriggersConfig = .default,
        priming: PrimingConfig = .default,
        audio: AudioConfig = .default,
        packsDirectory: URL = EngineConfig.defaultPacksDirectory,
        logging: LoggingConfig = .default
    ) {
        self.triggers = triggers
        self.priming = priming
        self.audio = audio
        self.packsDirectory = packsDirectory
        self.logging = logging
    }

    public static let `default` = EngineConfig()

    /// Default packs directory: `~/.config/yellback/packs/` with tilde expansion.
    public static let defaultPacksDirectory: URL = {
        let expanded = (("~/.config/yellback/packs/") as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }()
}

/// Detector enable/disable + per-detector tuning. Plain aggregator — each
/// leaf validates itself, so this init does not throw.
public struct TriggersConfig: Equatable {
    public let scream: ScreamConfig
    public let rageType: RageTypeConfig
    public let deskBang: DeskBangConfig

    public init(
        scream: ScreamConfig = .default,
        rageType: RageTypeConfig = .default,
        deskBang: DeskBangConfig = .default
    ) {
        self.scream = scream
        self.rageType = rageType
        self.deskBang = deskBang
    }

    public static let `default` = TriggersConfig()
}

/// Microphone scream detector config.
///
/// Field names in thrown `ConfigError.invalidValue` use the snake_case
/// spelling from `CONFIG_SCHEMA.md` (e.g. `dbfs_threshold`, not
/// `dbfsThreshold`) so the error message reads identically whether the
/// config was loaded from YAML or constructed in Swift.
public struct ScreamConfig: Equatable {
    public let enabled: Bool
    public let dbfsThreshold: Double
    public let sustainSeconds: Double
    public let voiceBandFilter: Bool
    public let cooldownSeconds: Double

    public init(
        enabled: Bool = true,
        dbfsThreshold: Double = -20,
        sustainSeconds: Double = 0.3,
        voiceBandFilter: Bool = true,
        cooldownSeconds: Double = 1.0
    ) throws {
        try ConfigValidation.checkDbfs(dbfsThreshold, field: "dbfs_threshold")
        try ConfigValidation.checkSecondsUpperBound(sustainSeconds, field: "sustain_seconds")
        try ConfigValidation.checkCooldown(cooldownSeconds, field: "cooldown_seconds")

        self.enabled = enabled
        self.dbfsThreshold = dbfsThreshold
        self.sustainSeconds = sustainSeconds
        self.voiceBandFilter = voiceBandFilter
        self.cooldownSeconds = cooldownSeconds
    }

    public static let `default` = try! ScreamConfig()
}

/// Keyboard rage-type detector config.
public struct RageTypeConfig: Equatable {
    public let enabled: Bool
    public let keystrokesPerSecondThreshold: Int
    public let rollingWindowSeconds: Double
    public let cooldownSeconds: Double

    public init(
        enabled: Bool = true,
        keystrokesPerSecondThreshold: Int = 8,
        rollingWindowSeconds: Double = 2.0,
        cooldownSeconds: Double = 1.5
    ) throws {
        if keystrokesPerSecondThreshold < 1 {
            throw ConfigError.invalidValue(
                field: "keystrokes_per_second_threshold",
                reason: "must be >= 1 (got \(keystrokesPerSecondThreshold))",
                line: nil
            )
        }
        try ConfigValidation.checkSecondsUpperBound(rollingWindowSeconds, field: "rolling_window_seconds")
        try ConfigValidation.checkCooldown(cooldownSeconds, field: "cooldown_seconds")

        self.enabled = enabled
        self.keystrokesPerSecondThreshold = keystrokesPerSecondThreshold
        self.rollingWindowSeconds = rollingWindowSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    public static let `default` = try! RageTypeConfig()
}

/// Accelerometer desk-bang detector config.
public struct DeskBangConfig: Equatable {
    public let enabled: Bool
    public let gForceThreshold: Double
    public let cooldownSeconds: Double

    public init(
        enabled: Bool = true,
        gForceThreshold: Double = 1.5,
        cooldownSeconds: Double = 0.8
    ) throws {
        if gForceThreshold <= 0 {
            throw ConfigError.invalidValue(
                field: "g_force_threshold",
                reason: "must be > 0 (got \(gForceThreshold))",
                line: nil
            )
        }
        try ConfigValidation.checkCooldown(cooldownSeconds, field: "cooldown_seconds")

        self.enabled = enabled
        self.gForceThreshold = gForceThreshold
        self.cooldownSeconds = cooldownSeconds
    }

    public static let `default` = try! DeskBangConfig()
}

/// Cross-trigger priming state config. See `ARCHITECTURE.md` for semantics.
public struct PrimingConfig: Equatable {
    public let enabled: Bool
    public let windowSeconds: Double
    public let thresholdMultiplier: Double

    public init(
        enabled: Bool = true,
        windowSeconds: Double = 5.0,
        thresholdMultiplier: Double = 0.75
    ) throws {
        try ConfigValidation.checkSecondsUpperBound(windowSeconds, field: "window_seconds")
        if thresholdMultiplier < 0.1 || thresholdMultiplier > 1.0 {
            throw ConfigError.invalidValue(
                field: "threshold_multiplier",
                reason: "must be in [0.1, 1.0] (got \(thresholdMultiplier))",
                line: nil
            )
        }

        self.enabled = enabled
        self.windowSeconds = windowSeconds
        self.thresholdMultiplier = thresholdMultiplier
    }

    public static let `default` = try! PrimingConfig()
}

/// Audio output config.
public struct AudioConfig: Equatable {
    /// `nil` means follow system volume. A numeric value in [0.0, 1.0] overrides.
    public let masterVolume: Double?
    public let pack: String

    public init(
        masterVolume: Double? = 0.8,
        pack: String = "crowd"
    ) throws {
        if let v = masterVolume, v < 0.0 || v > 1.0 {
            throw ConfigError.invalidValue(
                field: "master_volume",
                reason: "must be in [0.0, 1.0] or null (got \(v))",
                line: nil
            )
        }

        self.masterVolume = masterVolume
        self.pack = pack
    }

    public static let `default` = try! AudioConfig()
}

/// Logging config. No validation: `LogLevel` is enum-typed, so invalid levels
/// are impossible at the Swift type boundary. YAML-to-enum coercion (rejecting
/// strings outside the enum) happens in `ConfigLoader`.
public struct LoggingConfig: Equatable {
    public let level: LogLevel

    public init(level: LogLevel = .info) {
        self.level = level
    }

    public static let `default` = LoggingConfig()
}

/// Log levels, ordered from most-to-least verbose.
public enum LogLevel: String, Equatable, CaseIterable {
    case debug
    case info
    case warn
    case error
}
