import Foundation

/// Accelerometer-based desk-bang detector.
///
/// Reads the MacBook's Sudden Motion Sensor (SMS) / built-in accelerometer
/// via CoreMotion. Emits a `TriggerEvent` when the observed g-force delta
/// from a 1g baseline crosses threshold.
///
/// Accelerometer profiles differ between MacBook Pro 14" and 16" — detector
/// calibration should be verified on both.
final class AccelerometerDetector {}
