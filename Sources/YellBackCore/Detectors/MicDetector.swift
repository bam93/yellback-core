import Foundation

/// Microphone-based scream detector.
///
/// Computes RMS over a short window and (optionally) applies a 200Hz-3kHz
/// band-pass to restrict to the human voice range. Emits a `TriggerEvent`
/// when the level has been sustained above threshold for `sustain_seconds`.
///
/// Privacy: this detector reads level only. Audio is never buffered to disk,
/// never sent off device, never retained past the short analysis window.
final class MicDetector {}
