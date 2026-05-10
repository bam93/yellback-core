import Foundation

/// Engine-owned state that makes detectors cross-sensitive when a trigger has
/// recently fired.
///
/// Per `ARCHITECTURE.md` §"The Priming State": when any trigger fires, the
/// engine enters a primed window. While primed, the *other* triggers'
/// thresholds are multiplied by `priming.threshold_multiplier` (default 0.75),
/// making them easier to fire. The trigger that caused priming is NOT itself
/// easier to fire — this prevents auto-retrigger loops.
///
/// Detectors consult this state via the engine's `applyMultipliers()` step,
/// which sets each detector's `primingMultiplier` according to the current
/// phase. Detectors themselves do not query priming state directly.
///
/// `PrimingState` is a pure value type. It does NOT own a timer; the engine
/// schedules expiry via a `DispatchSourceTimer` and calls `tick(at:)` to
/// transition the state. All time arguments are `Date`s passed in by the
/// caller, which makes the state machine fully deterministic in tests.
public struct PrimingState: Equatable {

    /// The two phases of priming.
    public enum Phase: Equatable {
        /// No trigger has fired recently. All detectors run at base sensitivity.
        case idle

        /// A trigger fired at some point in the recent past; the engine
        /// considers other detectors more sensitive until `expiresAt`.
        case primed(originatingTrigger: Trigger, expiresAt: Date)
    }

    /// Current phase. Mutated only by the transition functions.
    public private(set) var phase: Phase = .idle

    public init() {}

    /// Returns the threshold multiplier the engine should apply to the given
    /// detector at `now`. `1.0` means "no priming, run at base threshold".
    /// During a primed window, the originating trigger gets `1.0` (auto-
    /// retrigger guard) and all other triggers get `config.thresholdMultiplier`.
    ///
    /// Non-mutating; safe to call from any thread that already holds the
    /// engine's serial queue.
    public func multiplier(for trigger: Trigger,
                           at now: Date,
                           config: PrimingConfig) -> Double {
        guard config.enabled else { return 1.0 }
        switch phase {
        case .idle:
            return 1.0
        case .primed(let originating, let expiresAt):
            // At and past expiresAt the multiplier returns to 1.0 even if
            // the engine has not yet ticked the state to .idle. This keeps
            // lookups correct between ticks.
            guard now < expiresAt else { return 1.0 }
            if trigger == originating {
                return 1.0
            } else {
                return config.thresholdMultiplier
            }
        }
    }

    /// Mutating transition called when a detector emits a `TriggerEvent`.
    /// Enters or refreshes the primed window. The window does NOT extend
    /// additively — a new trigger resets `expiresAt = now + windowSeconds`
    /// regardless of how much time was left.
    ///
    /// The new trigger becomes the originating trigger, taking on the
    /// auto-retrigger guard (multiplier 1.0 for itself).
    public mutating func onTrigger(_ trigger: Trigger,
                                   at now: Date,
                                   config: PrimingConfig) {
        let expiresAt = now.addingTimeInterval(config.windowSeconds)
        phase = .primed(originatingTrigger: trigger, expiresAt: expiresAt)
    }

    /// Mutating transition that the engine calls periodically to expire
    /// the primed window. If `now >= expiresAt`, transitions to `.idle`.
    public mutating func tick(at now: Date) {
        switch phase {
        case .idle:
            return
        case .primed(_, let expiresAt):
            if now >= expiresAt {
                phase = .idle
            }
        }
    }
}
