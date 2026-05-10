import Foundation

/// Counter-only session statistics. Owns no UI and surfaces no display logic —
/// consumers read the counters and render whatever they like.
///
/// The engine maintains a single `SessionStats` instance internally and
/// exposes a snapshot via `YellBackEngine.stats`. Counters are monotonically
/// non-decreasing for the lifetime of the engine.
///
/// `suppressedByMutedSystemCount` is forward-compat for Phase 4b (CoreAudio
/// system-mute detection). It exists in v1 to keep Phase 4b additive; until
/// that phase lands, the engine never increments it.
public struct SessionStats: Equatable {
    /// Number of `.scream` `TriggerEvent`s observed by the engine.
    public var screamCount: Int

    /// Number of `.rageType` `TriggerEvent`s observed by the engine.
    public var rageTypeCount: Int

    /// Number of `.deskBang` `TriggerEvent`s observed by the engine.
    public var deskBangCount: Int

    /// Number of times the engine actually called `SoundEngine.play(...)`.
    /// Always less than or equal to the sum of the per-trigger counts.
    public var playbackCount: Int

    /// Number of trigger events that were observed (and counted in their
    /// per-trigger field) but did NOT result in playback because the previous
    /// event of the same trigger was within `cooldownSeconds`. The consumer's
    /// activity log can use this to render "you were yelled-back-at suppressed
    /// by cooldown" hints.
    public var suppressedByCooldownCount: Int

    /// Number of trigger events that would have played but were skipped
    /// because the system is muted. Forward-compat — wired in Phase 4b.
    public var suppressedByMutedSystemCount: Int

    public init(
        screamCount: Int = 0,
        rageTypeCount: Int = 0,
        deskBangCount: Int = 0,
        playbackCount: Int = 0,
        suppressedByCooldownCount: Int = 0,
        suppressedByMutedSystemCount: Int = 0
    ) {
        self.screamCount = screamCount
        self.rageTypeCount = rageTypeCount
        self.deskBangCount = deskBangCount
        self.playbackCount = playbackCount
        self.suppressedByCooldownCount = suppressedByCooldownCount
        self.suppressedByMutedSystemCount = suppressedByMutedSystemCount
    }
}
