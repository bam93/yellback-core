import Foundation
import AVFoundation

/// Wraps `AVAudioEngine` + a fixed pool of `AVAudioPlayerNode`s and plays
/// clips from the active `SoundPack` in response to trigger events.
///
/// Per `AUDIO_NOTES.md`'s contract:
///
///   - The engine starts ONCE in `init()` and stays alive for this object's
///     lifetime. No engine restarts at trigger time, no engine restarts on
///     pack switch.
///   - 8 `AVAudioPlayerNode`s are pre-connected to `mainMixerNode` at init.
///     `play()` finds the first non-busy node, schedules the buffer with
///     `.interrupts`, and calls `play()`. **No allocation at trigger time.**
///   - All 8 busy → drop the trigger silently. Don't queue, don't allocate.
///   - System mute (`outputNode.outputVolume == 0`) → skip the trigger
///     entirely. The user muted for a reason.
///   - Tier (low / medium / high) is derived from intensity per
///     `AUDIO_NOTES.md`'s thresholds.
///   - No-repeat selection per tier: each tier has its own `recentlyPlayed`
///     set; selection excludes recently-played; on tier exhaustion the set
///     clears and selection is unconstrained until the cycle restarts.
///   - Volume mapping is `pow(intensity, 0.7)` for perceptual headroom,
///     then multiplied by the engine's `masterVolume` (or by 1.0 if the
///     master is `nil` = follow system).
///
/// Thread-safety: `play()` is callable from any thread. Internal state
/// mutations (node-pool scan, recentlyPlayed tracking) are serialized
/// through a private dispatch queue. `setPack(...)` and `stop()` are
/// expected to be called from one thread (typically the engine
/// lifecycle thread or the CLI's main thread); they're not cross-thread-safe
/// against concurrent `play()` calls without external synchronization.
public final class SoundEngine {

    // MARK: - Dependencies

    private let engine = AVAudioEngine()
    private let mixer: AVAudioMixerNode
    private let playerPool: [AVAudioPlayerNode]
    private let queue = DispatchQueue(label: "yellback.soundengine", qos: .userInteractive)

    /// Number of pre-allocated player nodes. Empirical per AUDIO_NOTES.md;
    /// 4 clipped during priming-state bursts, 16 added no observable benefit.
    public static let playerPoolSize = 8

    // MARK: - State

    /// Currently active pack. Nil until `setPack(...)` is called the first
    /// time. `play()` is a no-op when nil.
    public private(set) var pack: SoundPack?

    /// User-set master volume in [0.0, 1.0], or `nil` to follow system.
    /// Actual volume per buffer is
    /// `intensity_to_volume(intensity) * (masterVolume ?? 1.0)`.
    public var masterVolume: Double?

    /// Per-tier no-repeat tracking. Reset to empty on `setPack(...)`.
    private var recentlyPlayed: [Tier: Set<String>] = [
        .low: [], .medium: [], .high: []
    ]

    /// Deterministic source for clip selection — used by tests to pin the
    /// "which clip out of the eligible pool" decision. Default is the
    /// system random generator.
    private var rng: any RandomNumberGenerator

    // MARK: - Diagnostics

    /// When `true`, `play()` writes per-trigger latency timing to stderr
    /// (find-node-and-schedule micros). CLI sets this from
    /// `logging.level == .debug`. Default `false`.
    public var verboseDiagnostics: Bool = false

    // MARK: - Init

    /// Public production initializer. Builds 8 player nodes, attaches them
    /// to the engine, connects them all to `mainMixerNode`, prepares and
    /// starts the engine.
    ///
    /// Throws if `engine.start()` fails (audio hardware unavailable, etc.).
    public convenience init() throws {
        try self.init(rng: SystemRandomNumberGenerator())
    }

    /// Test initializer with a custom RNG so tests can lock the "which
    /// eligible clip" decision deterministically.
    init<R: RandomNumberGenerator>(rng: R) throws {
        // Eraser to `any RandomNumberGenerator` so we can mutate via the
        // existential's `next()`.
        self.rng = rng
        self.mixer = engine.mainMixerNode

        // Build the player pool. Attach all 8, connect each to the mixer
        // ONCE — never reconnect at trigger time.
        var nodes: [AVAudioPlayerNode] = []
        for _ in 0..<Self.playerPoolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            // Use the mixer's output format. Per AUDIO_NOTES.md, never
            // hardcode 44.1/16; read what the system reports.
            engine.connect(node, to: mixer, format: mixer.outputFormat(forBus: 0))
            nodes.append(node)
        }
        self.playerPool = nodes

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw error
        }
    }

    // MARK: - Public API

    /// Stop the engine cleanly. Active player nodes finish briefly per
    /// `AUDIO_NOTES.md`'s "Stopping cleanly" guidance — drop the reference
    /// without `stop()` and you get audible glitches.
    public func stop() {
        for node in playerPool {
            node.stop()
        }
        engine.stop()
    }

    /// Switch to `pack`. Buffers are already loaded by `PackLoader` —
    /// `setPack` only swaps the active reference and clears the per-tier
    /// no-repeat sets. Pack-load disk I/O happens in `PackLoader.load(...)`,
    /// which the consumer should run on a background queue.
    public func setPack(_ pack: SoundPack) {
        queue.sync {
            self.pack = pack
            self.recentlyPlayed = [.low: [], .medium: [], .high: []]
        }
    }

    /// Play a clip in response to a trigger of the given intensity.
    /// Selection: tier from intensity, then a random clip from the tier's
    /// non-recently-played pool (whole pool if recently-played is exhausted).
    /// Volume: `pow(intensity, 0.7)` × `masterVolume (?? 1.0)`.
    ///
    /// Skips entirely (no clip plays, no state change) if:
    ///   - no pack is loaded
    ///   - system output is muted (`outputVolume == 0`)
    ///   - all 8 player nodes are busy
    public func play(intensity: Double) {
        let started = ProcessInfo.processInfo.systemUptime
        queue.sync {
            self.playInternal(intensity: intensity, started: started)
        }
    }

    /// Number of player nodes currently playing. Exposed for tests +
    /// diagnostics; not part of the audio data path.
    public var activePlayerCount: Int {
        playerPool.lazy.filter { $0.isPlaying }.count
    }

    // MARK: - Internals (run on `queue`)

    private func playInternal(intensity: Double, started: TimeInterval) {
        guard let pack = pack else {
            if verboseDiagnostics {
                writeDiag("[diag] play() no-op: no pack loaded")
            }
            return
        }

        // System-mute check is deferred — see PROGRESS.md "Known Issues".
        // AUDIO_NOTES.md claims `outputNode.outputVolume` exposes the
        // muted state on macOS, but that property doesn't exist on
        // `AVAudioOutputNode`. Real macOS mute detection requires
        // CoreAudio (`kAudioDevicePropertyMute` on the default output
        // device). Until that lands, we play even when the system is
        // muted; the audio just goes nowhere audible. The user can stop
        // the daemon if it's annoying.

        guard let node = playerPool.first(where: { !$0.isPlaying }) else {
            if verboseDiagnostics {
                writeDiag("[diag] play() no-op: all \(Self.playerPoolSize) player nodes busy")
            }
            return
        }

        let tier = Tier(intensity: intensity)
        guard let clip = pickClip(tier: tier, pack: pack) else {
            // Should not happen — PackLoader rejects packs with empty tiers.
            return
        }

        // Volume: perceptual curve × user-set master (or 1.0 = follow system).
        let perceptualVolume = pow(intensity, 0.7)
        let master = masterVolume ?? 1.0
        node.volume = Float(perceptualVolume * master)

        node.scheduleBuffer(clip.buffer, at: nil, options: .interrupts, completionHandler: nil)
        node.play()

        // Mark this clip as recently played for its tier. Exhaustion check
        // happens at selection time (next call), not here.
        recentlyPlayed[tier, default: []].insert(clip.id)

        if verboseDiagnostics {
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000_000
            writeDiag(String(
                format: "[diag] play tier=%@ clip=%@ intensity=%.2f volume=%.2f scheduled in %.0fµs",
                String(describing: tier), clip.id, intensity, node.volume, elapsed
            ))
        }
    }

    private func pickClip(tier: Tier, pack: SoundPack) -> LoadedClip? {
        let allClips = pack.clips(in: tier)
        let played = recentlyPlayed[tier] ?? []

        var eligible = allClips.filter { !played.contains($0.id) }
        if eligible.isEmpty {
            // Whole tier was consumed since the last cycle reset.
            // Per AUDIO_NOTES.md: clear the set and select freely.
            recentlyPlayed[tier] = []
            eligible = allClips
        }
        guard !eligible.isEmpty else { return nil }
        let idx = Int.random(in: 0..<eligible.count, using: &rng)
        return eligible[idx]
    }

    private func writeDiag(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
