import Foundation

/// A discrete detection event. Fired when a detector crosses its threshold.
/// Consumed by the audio engine to select and play a clip.
public struct TriggerEvent {
    public let trigger: Trigger
    public let timestamp: Date
    public let intensity: Double
    public let wasPrimed: Bool

    public init(trigger: Trigger, timestamp: Date, intensity: Double, wasPrimed: Bool) {
        self.trigger = trigger
        self.timestamp = timestamp
        self.intensity = intensity
        self.wasPrimed = wasPrimed
    }
}

extension TriggerEvent {
    /// Single-line stderr/log rendering for the CLI's `--listen` mode and
    /// the paid Mac app's activity-log rows. Format:
    ///
    ///     [trigger] scream     intensity=0.85  dbfs=-9.00
    ///     [trigger] desk_bang  intensity=0.72  g_force=2.16 (primed)
    ///
    /// The detector-specific unit (`dbfs=` for scream, `g_force=` for
    /// desk-bang, placeholder for rage_type) is derived from `intensity`
    /// using the inverse of each detector's linear intensity mapping.
    /// These are approximate — the underlying detectors don't surface the
    /// raw measurement.
    ///
    /// Format is stable enough to grep but not part of the API contract;
    /// minor cosmetic changes are allowed. Pinned in tests so regressions
    /// (dropped fields, drifted padding, missing primed marker) fail loudly.
    public var consoleLogLine: String {
        let name = trigger.snakeCaseName.padding(toLength: 10, withPad: " ", startingAt: 0)
        let detail: String
        switch trigger {
        case .scream:
            let dbfs = intensity * 60 - 60
            detail = String(format: "dbfs=%.2f", dbfs)
        case .deskBang:
            let gForce = intensity * 3 + 1
            detail = String(format: "g_force=%.2f", gForce)
        case .rageType:
            detail = "keystrokes=?"
        }
        let primedMark = wasPrimed ? " (primed)" : ""
        return String(format: "[trigger] %@ intensity=%.2f  %@%@", name, intensity, detail, primedMark)
    }
}
