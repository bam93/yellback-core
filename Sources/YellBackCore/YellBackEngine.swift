import Foundation
import AVFoundation

/// Public entry point for YellBack detection and audio playback.
///
/// One engine per session. The consumer (CLI daemon or the paid Mac app)
/// builds an `EngineConfig`, instantiates the engine, attaches whatever
/// callbacks it cares about, and calls `start()`. Behaviour is identical
/// regardless of who is calling — UI concerns live entirely in the consumer.
///
/// The engine owns:
///
/// - The three detectors and their lifecycle (`start()` / `stop()`).
/// - The `SoundEngine` and pack loading.
/// - `PrimingState` cross-trigger coordination.
/// - Engine-level cooldown filtering using each detector's
///   `cooldownSeconds` from config. Cooldown-suppressed events still
///   fire `onTrigger` — only `SoundEngine.play(...)` is gated.
/// - `SessionStats` counters.
/// - The `PermissionState` surface.
///
/// **Thread safety:** all internal state mutations are serialized through a
/// private `DispatchQueue`. Consumer callbacks fire on threads as follows:
///
/// - `onTrigger` fires AFTER the engine releases its serial queue, so
///   consumers may safely call back into engine methods (`stats`,
///   `setPack`, `loadPack`) from the callback without deadlocking.
/// - `onIntensity` fires on the originating detector's own thread (audio
///   tap thread for scream, IOKit run-loop thread for desk-bang). This
///   keeps the high-rate path cheap; consumers must not block in this
///   callback and must hop to their own thread before touching UI.
/// - `onPermissionStateChange` fires asynchronously on the engine queue
///   shortly after `start()` returns.
///
/// Consumers must hop to their own UI thread before touching UI from any
/// of these callbacks.
///
/// See `ARCHITECTURE.md` for the signal/event model and the priming state.
public final class YellBackEngine {

    // MARK: - Public callbacks

    /// Called for every `TriggerEvent` from any detector — including events
    /// suppressed by cooldown (consumers see all events; only audio playback
    /// is gated).
    public var onTrigger: ((TriggerEvent) -> Void)?

    /// Called at each detector's sample rate with a continuous 0.0-1.0
    /// signal, regardless of threshold. v1 consumers typically ignore this;
    /// v2's planned fusion module consumes it. The `Trigger` argument tells
    /// the consumer which detector emitted the signal — added by the engine
    /// because per-detector callbacks don't carry this discriminator.
    public var onIntensity: ((Trigger, IntensitySignal) -> Void)?

    /// Called when the status of a required macOS permission changes. Fires
    /// once at `start()` with the initial state; future phases (KeyboardDetector
    /// in Phase 6) will re-fire when the user toggles Accessibility at runtime.
    public var onPermissionStateChange: ((PermissionState) -> Void)?

    // MARK: - Internal state (queue-protected)

    private let config: EngineConfig
    private let queue = DispatchQueue(label: "yellback.engine", qos: .userInteractive)

    private var detectors: [Detector] = []
    private var soundEngine: SoundEngine?
    private var primingState = PrimingState()
    private var lastDispatchedAt: [Trigger: Date] = [:]
    private var statsStorage = SessionStats()
    private var primingExpiryTimer: DispatchSourceTimer?
    private var startupWarningsStorage: [String] = []

    /// Test-only override that captures `play(intensity:)` calls without
    /// requiring a real `SoundEngine`. When non-nil, `soundEngine` is
    /// bypassed for playback. Production paths leave this `nil`.
    private let playbackRecorder: ((Double) -> Void)?

    // MARK: - Init

    /// Public production initializer. Stores the validated config; defers
    /// hardware setup (AVAudioEngine, IOKit HID) to `start()`.
    public init(config: EngineConfig) {
        self.config = config
        self.playbackRecorder = nil
    }

    /// Internal test initializer. Accepts pre-built detectors so tests can
    /// inject `FakeDetector`s and a `playbackRecorder` closure that observes
    /// audio dispatch without spinning up `AVAudioEngine`.
    ///
    /// Tests typically do NOT call `start()` after this — they wire callbacks
    /// in this initializer and immediately exercise the handlers via the
    /// fake detectors.
    internal init(
        config: EngineConfig,
        detectors: [Detector],
        playbackRecorder: ((Double) -> Void)?
    ) {
        self.config = config
        self.playbackRecorder = playbackRecorder
        self.detectors = detectors
        wireDetectorCallbacks()
    }

    // MARK: - Lifecycle

    /// Build the SoundEngine, load the configured pack, build and start the
    /// enabled detectors. Throws `EngineError.noDetectorsStarted` only if
    /// neither audio nor any detector came up — partial success is normal
    /// (matches CLI's graceful-degradation behavior).
    public func start() throws {
        var failureReasons: [String] = []

        // 1. Bring up the audio engine. Failure is non-fatal: triggers fire
        //    silently. Matches the current CLI's behavior.
        do {
            let engine = try SoundEngine()
            engine.verboseDiagnostics = (config.logging.level == .debug)
            engine.masterVolume = config.audio.masterVolume
            self.soundEngine = engine
        } catch {
            failureReasons.append("SoundEngine failed: \(error)")
            self.soundEngine = nil
        }

        // 2. Try to load the configured pack. Non-fatal — engine without a
        //    pack just doesn't play audio (still emits triggers + stats).
        if soundEngine != nil {
            do {
                try setPackInternal(id: config.audio.pack)
            } catch {
                failureReasons.append("pack load failed: \(error)")
            }
        }

        // 3. Build the enabled detectors. KeyboardDetector for rage_type
        //    is still a stub in this phase; emit a one-line warning and skip.
        var built: [Detector] = []
        if config.triggers.scream.enabled {
            built.append(MicDetector(config: config.triggers.scream))
        }
        if config.triggers.deskBang.enabled {
            let detector = AccelerometerDetector(config: config.triggers.deskBang)
            detector.verboseDiagnostics = (config.logging.level == .debug)
            built.append(detector)
        }
        if config.triggers.rageType.enabled {
            failureReasons.append("rage_type enabled in config but KeyboardDetector not yet implemented")
        }

        self.detectors = built
        wireDetectorCallbacks()

        // 4. Start each detector. Per-detector failure is non-fatal so other
        //    detectors keep working (e.g. mic denied → desk-bang still runs).
        var startedDetectors: [Detector] = []
        for d in detectors {
            do {
                try d.start()
                startedDetectors.append(d)
            } catch {
                failureReasons.append("\(d.trigger.snakeCaseName) detector failed to start: \(error)")
            }
        }
        self.detectors = startedDetectors

        // 5. Hard failure only if NOTHING is up. If at least one detector
        //    started OR the audio engine is up, succeed.
        if startedDetectors.isEmpty && soundEngine == nil {
            throw EngineError.noDetectorsStarted(reasons: failureReasons)
        }

        // 6. Stash partial-start warnings so consumers can surface them. The
        //    CLI reads `startupWarnings` after start() and prints each line
        //    to stderr; the paid app shows them in its activity panel.
        startupWarningsStorage = failureReasons

        // 7. Emit initial PermissionState from the engine queue.
        emitPermissionState()
    }

    /// Stop detectors, the SoundEngine, and the priming-expiry timer.
    /// Idempotent — safe to call when already stopped.
    public func stop() {
        // Snapshot the detector list under the queue, then call each
        // detector's `stop()` OUTSIDE the queue. `Detector.stop()` may
        // join with its callback thread, which itself may be blocked
        // waiting to enter our queue — calling it inside `queue.sync`
        // would deadlock that path.
        let detectorsSnapshot: [Detector] = queue.sync {
            primingExpiryTimer?.cancel()
            primingExpiryTimer = nil
            let snapshot = self.detectors
            self.detectors = []
            return snapshot
        }
        for d in detectorsSnapshot {
            d.stop()
        }
        soundEngine?.stop()
    }

    // MARK: - Pack loading

    /// Switch to the pack with the given id. Resolves against
    /// `config.packsDirectory`. Preloads the pack's clips before returning so
    /// trigger latency stays under budget on the first fire.
    ///
    /// Safe to call from any thread, including from inside an `onTrigger`
    /// callback — does not take the engine queue. The underlying
    /// `SoundEngine.setPack(_:)` is itself thread-safe (per its docstring).
    public func setPack(id: String) throws {
        try setPackInternal(id: id)
    }

    /// Load a pack from an arbitrary filesystem location (paid-app sideloads
    /// or CLI overrides). Same effect on the engine as `setPack(id:)`.
    public func loadPack(from url: URL) throws {
        try loadPackInternal(from: url)
    }

    // MARK: - Public observers

    /// Snapshot of the current session counters. Read-only; consumers can
    /// poll this on a UI cadence or render on each `onTrigger` callback.
    public var stats: SessionStats {
        return queue.sync { statsStorage }
    }

    /// Warnings collected during the most recent `start()`. Empty when
    /// every component (SoundEngine, pack, all detectors) came up cleanly.
    /// Non-empty when the engine succeeded with partial coverage —
    /// consumers should surface each line so the user knows which piece
    /// is silent. Reset by each `start()`.
    public var startupWarnings: [String] {
        return queue.sync { startupWarningsStorage }
    }

    /// Triggers that actually came up during the most recent `start()`.
    /// Empty before `start()` is called. The CLI prints a summary so the
    /// user has positive confirmation that detectors are running.
    public var startedTriggers: [Trigger] {
        return queue.sync { detectors.map { $0.trigger } }
    }

    // MARK: - Detector wiring

    private func wireDetectorCallbacks() {
        for d in detectors {
            // Capture trigger + weak self so the detector closure doesn't
            // retain the engine and doesn't reach into a deallocated one.
            let trigger = d.trigger
            d.onTriggerEvent = { [weak self] event in
                self?.handleTriggerEvent(event)
            }
            d.onIntensitySignal = { [weak self] signal in
                self?.handleIntensitySignal(signal, from: trigger)
            }
        }
    }

    // MARK: - Event handlers (run on the engine's serial queue)

    private func handleTriggerEvent(_ event: TriggerEvent) {
        // Mutate engine state inside the queue, then return a "what to do
        // next" decision so consumer callbacks and audio playback fire
        // OUTSIDE the queue. This lets consumers call back into engine
        // methods (`stats`, `setPack`, `loadPack`) from `onTrigger` without
        // deadlocking on the same serial queue.
        let intensityToPlay: Double? = queue.sync {
            // 1. Increment per-trigger counter — every observed event counts.
            switch event.trigger {
            case .scream:    statsStorage.screamCount += 1
            case .rageType:  statsStorage.rageTypeCount += 1
            case .deskBang:  statsStorage.deskBangCount += 1
            }

            // 2. Cooldown gate: only the playback path is gated.
            let cooldown = lookupCooldownSeconds(event.trigger)
            var play: Double? = nil
            if let last = lastDispatchedAt[event.trigger],
               event.timestamp.timeIntervalSince(last) < cooldown {
                statsStorage.suppressedByCooldownCount += 1
            } else {
                lastDispatchedAt[event.trigger] = event.timestamp
                statsStorage.playbackCount += 1
                play = event.intensity
            }

            // 3. Update PrimingState and propagate the new multipliers to
            //    every detector. Done AFTER playback gating so the priming
            //    state captures every observed event regardless of cooldown.
            primingState.onTrigger(event.trigger, at: event.timestamp, config: config.priming)
            applyMultipliers(now: Date())
            scheduleExpiryTimer()

            return play
        }

        // 4. Forward to consumer UNCONDITIONALLY (off-queue). Cooldown-
        //    suppressed events still fire onTrigger so consumers see all
        //    events.
        onTrigger?(event)

        // 5. Drive playback off-queue. SoundEngine has its own serial
        //    queue and a dispatch into it is a single hop.
        if let intensity = intensityToPlay {
            if let recorder = playbackRecorder {
                recorder(intensity)
            } else {
                soundEngine?.play(intensity: intensity)
            }
        }
    }

    private func handleIntensitySignal(_ signal: IntensitySignal, from trigger: Trigger) {
        // No state change; pure forward. Do NOT take the queue — the
        // intensity signal stream is high-rate (sample-rate) and the
        // forward closure must stay cheap. The consumer is responsible
        // for thread safety on its side.
        onIntensity?(trigger, signal)
    }

    // MARK: - Priming wiring

    private func applyMultipliers(now: Date) {
        for detector in detectors {
            detector.primingMultiplier = primingState.multiplier(
                for: detector.trigger, at: now, config: config.priming
            )
        }
    }

    /// Schedule a one-shot timer to fire when the current primed window
    /// expires. The timer transitions PrimingState to `.idle` and re-applies
    /// multipliers to all detectors. Cancels any previous pending timer
    /// (window resets are common — they replace, not extend).
    private func scheduleExpiryTimer() {
        primingExpiryTimer?.cancel()
        primingExpiryTimer = nil

        // Only schedule if currently primed and the window hasn't already
        // passed. State machine handles the rest deterministically.
        guard case .primed(_, let expiresAt) = primingState.phase else { return }
        let interval = expiresAt.timeIntervalSinceNow
        guard interval > 0 else {
            // Already expired (timer is racing real time); transition now.
            primingState.tick(at: Date())
            applyMultipliers(now: Date())
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.handleExpiryTick()
        }
        primingExpiryTimer = timer
        timer.resume()
    }

    /// Runs on the engine queue (the timer fires there). Drives
    /// `PrimingState` to idle and re-applies 1.0 multipliers to all
    /// detectors so subsequent firings are evaluated at base threshold.
    private func handleExpiryTick() {
        primingState.tick(at: Date())
        applyMultipliers(now: Date())
        primingExpiryTimer = nil
    }

    // MARK: - Cooldown lookup

    private func lookupCooldownSeconds(_ trigger: Trigger) -> Double {
        switch trigger {
        case .scream:    return config.triggers.scream.cooldownSeconds
        case .rageType:  return config.triggers.rageType.cooldownSeconds
        case .deskBang:  return config.triggers.deskBang.cooldownSeconds
        }
    }

    // MARK: - Pack loading internals (queue-held)

    private func setPackInternal(id: String) throws {
        let dir = config.packsDirectory.appendingPathComponent(id)
        let manifest = dir.appendingPathComponent("pack.yaml")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw EngineError.packNotFound(id: id, searchedAt: dir)
        }
        try loadPackInternal(from: dir)
    }

    private func loadPackInternal(from url: URL) throws {
        guard let engine = soundEngine else {
            throw EngineError.audioEngineUnavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ) else {
            throw EngineError.audioFormatUnavailable
        }
        let pack = try PackLoader.load(from: url, outputFormat: outputFormat)
        engine.setPack(pack)
    }

    // MARK: - Permission surfacing

    private func emitPermissionState() {
        // Mic permission is read synchronously from AVCaptureDevice's TCC
        // status. Accessibility permission tracking arrives in Phase 6
        // (KeyboardDetector); for now it's `.notDetermined`.
        let mic = micPermissionStatus()
        let access: PermissionStatus = .notDetermined
        let state = PermissionState(microphone: mic, accessibility: access)
        queue.async { [weak self] in
            self?.onPermissionStateChange?(state)
        }
    }

    private func micPermissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .denied
        @unknown default:    return .notDetermined
        }
    }
}

// MARK: - Errors

/// Errors specific to `YellBackEngine` lifecycle and pack management.
public enum EngineError: Error, Equatable, CustomStringConvertible {
    /// `start()` was called but neither the SoundEngine nor any detector
    /// could be brought up. The reasons collected during start are returned
    /// for diagnostic / log rendering.
    case noDetectorsStarted(reasons: [String])

    /// `setPack(id:)` resolved to a directory that doesn't contain a
    /// `pack.yaml`. The CLI / paid app should treat this as a config error
    /// (the pack id doesn't match any available pack).
    case packNotFound(id: String, searchedAt: URL)

    /// Could not construct an `AVAudioFormat` for pack loading. Should
    /// not happen on supported platforms — surfaces as an error rather
    /// than crashing.
    case audioFormatUnavailable

    /// `setPack`/`loadPack` was called but `SoundEngine` failed during
    /// `start()` (or was never started). Loading would silently no-op,
    /// so we throw instead — the consumer needs to know that audio
    /// switching is currently impossible.
    case audioEngineUnavailable

    public var description: String {
        switch self {
        case .noDetectorsStarted(let reasons):
            return "engine: no detectors started: " + reasons.joined(separator: "; ")
        case .packNotFound(let id, let url):
            return "engine: pack '\(id)' not found at \(url.path)"
        case .audioFormatUnavailable:
            return "engine: AVAudioFormat construction failed"
        case .audioEngineUnavailable:
            return "engine: audio engine unavailable; cannot switch packs"
        }
    }
}

// MARK: - PermissionState

/// Snapshot of required macOS permissions at a moment in time.
public struct PermissionState: Equatable {
    public let microphone: PermissionStatus
    public let accessibility: PermissionStatus

    public init(microphone: PermissionStatus, accessibility: PermissionStatus) {
        self.microphone = microphone
        self.accessibility = accessibility
    }
}

/// Tri-state permission status. The engine reports this rather than prompting
/// for permissions itself — prompting is the consumer's job.
public enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}
