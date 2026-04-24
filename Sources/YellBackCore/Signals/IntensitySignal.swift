import Foundation

/// A continuous per-detector "how much is happening right now" sample.
///
/// Emitted at each detector's sample rate regardless of threshold crossings.
/// v1 consumers typically ignore this; v2's planned multimodal fusion module
/// consumes it to compute a unified frustration score.
public struct IntensitySignal {
    public let value: Double
    public let timestamp: Date

    public init(value: Double, timestamp: Date) {
        self.value = value
        self.timestamp = timestamp
    }
}
