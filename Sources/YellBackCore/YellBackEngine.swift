import Foundation

/// Public entry point for YellBack detection and audio playback.
///
/// One engine per session. The consumer (CLI daemon or the paid Mac app) builds
/// an `EngineConfig`, instantiates the engine, attaches whatever callbacks it
/// cares about, and calls `start()`. Behaviour is identical regardless of who
/// is calling — UI concerns live entirely in the consumer.
///
/// See `ARCHITECTURE.md` for the signal/event model and the priming state.
public final class YellBackEngine {
    /// Construct an engine with a validated config. In v1, config is typically
    /// produced by `ConfigLoader` from a YAML file.
    public init(config: EngineConfig) {}

    /// Start the detectors and audio engine. Throws if a required permission
    /// is denied or if audio setup fails.
    public func start() throws {}

    /// Stop detectors and audio playback. Safe to call when already stopped.
    public func stop() {}

    /// Switch to the pack with the given id. Preloads the pack's clips before
    /// returning so trigger latency stays under budget on the first fire.
    public func setPack(id: String) throws {}

    /// Load a pack from an arbitrary filesystem location (for paid-app sideloads
    /// or CLI `--pack` overrides).
    public func loadPack(from url: URL) throws {}

    /// Called when a detector crosses threshold and the audio engine should
    /// respond.
    public var onTrigger: ((TriggerEvent) -> Void)?

    /// Called at each detector's sample rate with a continuous 0.0-1.0 signal,
    /// regardless of threshold. v1 consumers typically ignore this; v2's
    /// planned fusion module consumes it.
    public var onIntensity: ((Trigger, IntensitySignal) -> Void)?

    /// Called when the status of a required macOS permission changes.
    public var onPermissionStateChange: ((PermissionState) -> Void)?
}

/// Snapshot of required macOS permissions at a moment in time.
public struct PermissionState {
    public let microphone: PermissionStatus
    public let accessibility: PermissionStatus

    public init(microphone: PermissionStatus, accessibility: PermissionStatus) {
        self.microphone = microphone
        self.accessibility = accessibility
    }
}

/// Tri-state permission status. The engine reports this rather than prompting
/// for permissions itself — prompting is the consumer's job.
public enum PermissionStatus {
    case notDetermined
    case granted
    case denied
}
