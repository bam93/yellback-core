import Foundation
import AVFoundation

/// Three intensity tiers a `Trigger`'s intensity is bucketed into for clip
/// selection. Thresholds are hardcoded per `AUDIO_NOTES.md` ("Tier Selection")
/// — they're not user-tunable.
public enum Tier: CaseIterable {
    case low
    case medium
    case high

    /// Map a [0.0, 1.0] intensity to its tier.
    ///   `0.0...<0.33` → low
    ///   `0.33...<0.66` → medium
    ///   `0.66...1.0`  → high
    public init(intensity: Double) {
        let clamped = max(0.0, min(1.0, intensity))
        if clamped < 0.33 {
            self = .low
        } else if clamped < 0.66 {
            self = .medium
        } else {
            self = .high
        }
    }
}

/// One clip loaded into memory and ready to play. Constructed at pack-switch
/// time by `PackLoader`; held by `SoundPack`. The `id` is the on-disk
/// filename (without path) — used as the no-repeat key per
/// `AUDIO_NOTES.md`'s no-repeat rule.
public struct LoadedClip: Equatable {
    public let id: String
    public let buffer: AVAudioPCMBuffer

    public init(id: String, buffer: AVAudioPCMBuffer) {
        self.id = id
        self.buffer = buffer
    }

    public static func == (lhs: LoadedClip, rhs: LoadedClip) -> Bool {
        // Buffers are reference types; identity comparison is sufficient,
        // and we rarely need full content-equality for these.
        lhs.id == rhs.id && lhs.buffer === rhs.buffer
    }
}

/// A fully-loaded sound pack: metadata + clips bucketed by tier, ready for
/// `SoundEngine` to play from. Produced by `PackLoader.load(...)` at
/// pack-switch time. All clip `AVAudioPCMBuffer`s are decoded and resampled
/// to the engine's output format up-front, so trigger-time playback does
/// zero disk I/O and zero format conversion (the 100ms latency budget per
/// `AUDIO_NOTES.md` only holds with this property).
public struct SoundPack {
    public let id: String
    public let name: String

    /// Clips per tier. Every tier is required to be non-empty by
    /// `PackLoader`'s validation — a tier with no clips couldn't satisfy
    /// no-repeat selection cleanly. Packs that "feel" single-tier (like the
    /// initial Crowd pack) duplicate the same clip list across all three.
    public let tiers: [Tier: [LoadedClip]]

    public init(id: String, name: String, tiers: [Tier: [LoadedClip]]) {
        self.id = id
        self.name = name
        self.tiers = tiers
    }

    /// Return the clip array for a given tier. Asserts the tier is present
    /// and non-empty — both invariants are enforced by `PackLoader`.
    public func clips(in tier: Tier) -> [LoadedClip] {
        guard let list = tiers[tier], !list.isEmpty else {
            preconditionFailure("SoundPack.\(id) has no clips in tier \(tier); PackLoader should have rejected this pack")
        }
        return list
    }
}
