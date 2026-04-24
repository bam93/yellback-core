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
