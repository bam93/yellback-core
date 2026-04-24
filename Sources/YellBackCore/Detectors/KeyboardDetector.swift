import Foundation

/// Keyboard-timing-based rage-type detector.
///
/// Reads keystroke *timing* from a `CGEventTap` and computes keys-per-second
/// over a rolling window. Emits a `TriggerEvent` when the rate crosses the
/// configured threshold.
///
/// Privacy: key *content* is never inspected, logged, or buffered. Only the
/// timestamp of each keydown event is used.
final class KeyboardDetector {}
