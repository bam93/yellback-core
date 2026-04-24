import Foundation

/// The contract every detector in `yellback-core` conforms to.
///
/// Per `ARCHITECTURE.md` ("Why Three Independent Detectors"), each detector
/// is a self-contained component that owns its own threshold, intensity
/// calculation, and input-source plumbing. Detectors do not share state with
/// each other; cross-trigger behaviour (the priming state) is mediated by
/// `YellBackEngine`, never by detector-to-detector communication.
///
/// ## What detectors emit
///
/// Per `ARCHITECTURE.md` ("The Signal/Event Duality"):
///
///   - `onTriggerEvent`: discrete `TriggerEvent` when this detector decides
///     "yes, the user just did the thing." Fires at the detector's natural
///     event cadence (e.g. for `MicDetector`, once per sustain window of
///     above-threshold audio; for `AccelerometerDetector`, once per impulse).
///
///   - `onIntensitySignal`: continuous `IntensitySignal` emitted at the
///     detector's sample rate regardless of threshold. The v1 audio engine
///     ignores this; v2's planned multimodal-fusion module consumes it.
///     Both callbacks are required — a detector that "forgets" to emit
///     intensity signals violates the contract at the type level.
///
/// ## What detectors do NOT do
///
/// **Cooldown enforcement.** Detectors emit at their natural cadence; the
/// engine is responsible for filtering rapid-fire events before they reach
/// audio playback. This keeps detectors stateless w.r.t. cooldowns and lets
/// the engine see every event for stats and priming-state purposes.
///
/// **Permission requests.** Some detectors need user-granted permissions
/// (microphone for `MicDetector`, accessibility for `KeyboardDetector`).
/// `start()` does not prompt — that's the consumer's job. If a permission
/// hasn't been granted, `start()` may succeed but produce no output (e.g.
/// the mic tap delivers silence). Consumers should check permission state
/// before calling `start()`.
///
/// **Engine-level coordination.** Priming state is held by `YellBackEngine`;
/// each detector exposes a way to receive the engine's current priming
/// multiplier (e.g. `MicDetector.primingMultiplier`), but the detector does
/// not query or compute priming state itself.
///
/// ## Lifecycle
///
/// `start()` and `stop()` are expected to be idempotent — calling `start()`
/// twice replaces the input source; calling `stop()` when already stopped
/// is a no-op. `isEnabled` is a runtime gate: a detector that is `start()`-ed
/// but `isEnabled == false` should produce no callbacks.
public protocol Detector: AnyObject {
    /// The trigger type this detector emits. One of `.scream`, `.rageType`,
    /// `.deskBang` — every detector emits exactly one type.
    var trigger: Trigger { get }

    /// Runtime enable/disable. Defaults to whatever the detector's config
    /// says at init. The engine may toggle this at runtime (e.g. when the
    /// user disables a trigger via the paid app's settings UI). When
    /// `false`, no callbacks fire even if `start()` has been called.
    var isEnabled: Bool { get set }

    /// Discrete event callback. Set by the engine before `start()`.
    var onTriggerEvent: ((TriggerEvent) -> Void)? { get set }

    /// Continuous signal callback, fired at the detector's sample rate
    /// regardless of threshold. Set by the engine before `start()`.
    var onIntensitySignal: ((IntensitySignal) -> Void)? { get set }

    /// Begin observing the detector's input source (mic / keyboard /
    /// accelerometer). Throws on hardware unavailability or input-setup
    /// failure. Idempotent — replaces any previously-installed input.
    func start() throws

    /// Stop observing. Safe to call when already stopped.
    func stop()
}

/// Errors common to every `Detector`.
public enum DetectorError: Error, Equatable {
    /// The hardware required by this detector is not present on this Mac
    /// (e.g. accelerometer on a Mac mini, Mac Studio, or base M1 MacBook).
    case hardwareUnavailable(trigger: Trigger, reason: String)

    /// The detector's input source could not be configured. Wraps the
    /// underlying error's localized description for human-readable output.
    case inputSetupFailed(trigger: Trigger, underlying: String)

    /// The detector needs privileged access that the current process
    /// doesn't have — e.g. `AccelerometerDetector` reading the Apple SPU
    /// HID device requires root (`sudo`) or a helper with equivalent
    /// privilege. The consumer's job is to gate `start()` on privilege,
    /// or to surface this error to the user with actionable text.
    case needsPrivilegedAccess(trigger: Trigger, reason: String)
}

extension DetectorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .hardwareUnavailable(let trigger, let reason):
            return "\(trigger) detector hardware unavailable: \(reason)"
        case .inputSetupFailed(let trigger, let underlying):
            return "\(trigger) detector input setup failed: \(underlying)"
        case .needsPrivilegedAccess(let trigger, let reason):
            return "\(trigger) detector needs privileged access: \(reason)"
        }
    }
}
