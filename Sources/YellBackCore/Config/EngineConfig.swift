import Foundation

/// Root config consumed by `YellBackEngine`. Produced by `ConfigLoader` from
/// a YAML file matching `CONFIG_SCHEMA.md`.
///
/// Every field has a documented default sourced from `config.example.yaml`,
/// so callers can construct a usable `EngineConfig()` without a file.
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

    /// Default packs directory: `~/.config/yellback/packs/` with tilde expansion.
    public static let defaultPacksDirectory: URL = {
        let expanded = (("~/.config/yellback/packs/") as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }()
}

/// Detector enable/disable + per-detector tuning.
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
    ) {
        self.enabled = enabled
        self.dbfsThreshold = dbfsThreshold
        self.sustainSeconds = sustainSeconds
        self.voiceBandFilter = voiceBandFilter
        self.cooldownSeconds = cooldownSeconds
    }

    public static let `default` = ScreamConfig()
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
    ) {
        self.enabled = enabled
        self.keystrokesPerSecondThreshold = keystrokesPerSecondThreshold
        self.rollingWindowSeconds = rollingWindowSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    public static let `default` = RageTypeConfig()
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
    ) {
        self.enabled = enabled
        self.gForceThreshold = gForceThreshold
        self.cooldownSeconds = cooldownSeconds
    }

    public static let `default` = DeskBangConfig()
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
    ) {
        self.enabled = enabled
        self.windowSeconds = windowSeconds
        self.thresholdMultiplier = thresholdMultiplier
    }

    public static let `default` = PrimingConfig()
}

/// Audio output config.
public struct AudioConfig: Equatable {
    /// `nil` means follow system volume. A numeric value in [0.0, 1.0] overrides.
    public let masterVolume: Double?
    public let pack: String

    public init(
        masterVolume: Double? = 0.8,
        pack: String = "crowd"
    ) {
        self.masterVolume = masterVolume
        self.pack = pack
    }

    public static let `default` = AudioConfig()
}

/// Logging config.
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
