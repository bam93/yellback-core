import Foundation
@testable import YellBackCore

/// Synthetic `AccelerometerSample` generators for `AccelerometerDetector`
/// tests. The accelerometer reads ~1g at rest due to gravity, so all
/// helpers assume that baseline — `still()` returns samples at `(0, 0, 1g)`,
/// not `(0, 0, 0)`.
///
/// Timestamps advance by `1/100` seconds per sample (the detector's 100Hz
/// polling rate), counted from a test-local epoch. Absolute values don't
/// matter for the detector — it only uses `abs(magnitude - 1.0)` — but
/// non-decreasing timestamps keep tests honest if anyone ever adds time-
/// based logic.
enum MotionFixtures {
    static let samplesPerSecond: Double = 100

    /// Single sample of a Mac at rest (accelerometer reading gravity only).
    static func still(at t: TimeInterval = 0) -> AccelerometerSample {
        AccelerometerSample(x: 0, y: 0, z: 1.0, timestamp: t)
    }

    /// Single sample at a specified g-force magnitude above rest — useful
    /// for threshold-boundary tests. Direction is up (+z).
    static func sample(gForceMagnitude: Double, at t: TimeInterval = 0) -> AccelerometerSample {
        AccelerometerSample(x: 0, y: 0, z: gForceMagnitude, timestamp: t)
    }

    /// A sequence of still samples for `durationMs` ms at 100Hz — used to
    /// flood the detector with resting data and confirm it doesn't trigger
    /// spuriously.
    static func stillFor(durationMs: Int, startingAt t0: TimeInterval = 0) -> [AccelerometerSample] {
        sequence(durationMs: durationMs, startingAt: t0) { _ in (0, 0, 1.0) }
    }

    /// A sequence that is still except for a single sample at `tapAtMs`
    /// milliseconds in, carrying the given magnitude. Simulates a single
    /// impulsive desk bang.
    static func stillWithSingleTap(
        gForceMagnitude: Double,
        tapAtMs: Int,
        totalDurationMs: Int,
        startingAt t0: TimeInterval = 0
    ) -> [AccelerometerSample] {
        let tapSample = Int(Double(tapAtMs) / 1000.0 * samplesPerSecond)
        return sequence(durationMs: totalDurationMs, startingAt: t0) { i in
            i == tapSample ? (0, 0, gForceMagnitude) : (0, 0, 1.0)
        }
    }

    /// Build a sequence of samples, calling `sampleAt(i)` for the XYZ values
    /// at sample index `i`. Timestamps advance at 100Hz.
    static func sequence(
        durationMs: Int,
        startingAt t0: TimeInterval = 0,
        sampleAt: (Int) -> (Double, Double, Double)
    ) -> [AccelerometerSample] {
        let n = Int(Double(durationMs) / 1000.0 * samplesPerSecond)
        let dt = 1.0 / samplesPerSecond
        var out: [AccelerometerSample] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let (x, y, z) = sampleAt(i)
            out.append(AccelerometerSample(x: x, y: y, z: z, timestamp: t0 + Double(i) * dt))
        }
        return out
    }
}
