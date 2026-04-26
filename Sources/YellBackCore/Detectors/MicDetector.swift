import Foundation
import AVFoundation

/// Microphone-based scream detector. Conforms to `Detector` (see
/// `Detector.swift` for the full contract).
///
/// Consumes `AVAudioPCMBuffer`s of mono Float32 samples, optionally applies a
/// 200Hz-3kHz Butterworth band-pass (cascade of two 2nd-order biquads), and
/// computes RMS-based dBFS per buffer. Emits:
///
///   - A continuous `IntensitySignal` every `process(buffer:)` call, regardless
///     of threshold (consumed by v2 fusion; v1 consumers may ignore).
///   - A discrete `TriggerEvent` when dBFS has stayed at or above the
///     effective threshold for at least `sustainSeconds`. Sustain resets
///     after each emission, so continuous loud audio fires at sustain
///     cadence (~1/sustainSeconds Hz).
///
/// **Cooldown is engine-level**, not detector-level. Per the project's
/// architectural decision, detectors emit at their natural cadence; the
/// engine filters rapid-fire events before they reach audio playback. This
/// lets the engine see every event for stats and priming-state purposes.
///
/// ## Privacy invariant
///
/// Retains no audio samples between `process(buffer:)` calls beyond the
/// **8 samples** of biquad filter history (two 2nd-order sections × four
/// samples of state each). A debug-build `precondition` fires if any change
/// causes `retainedAudioSampleCount` to exceed 8.
///
/// ## Timekeeping
///
/// Sustain logic uses a sample-accurate monotonic clock computed as
/// `processedSamples / sampleRate`. Deterministic across live audio and
/// synthetic test buffers. `TriggerEvent.timestamp` uses wall-clock `Date()`
/// for human-readable reporting.
///
/// ## Threading
///
/// `process(buffer:)` runs on the audio-tap callback thread. `start()` and
/// `stop()` are expected to be called from one other thread (e.g. the engine
/// lifecycle thread or the CLI's main thread). Callback properties
/// (`onTriggerEvent`, `onIntensitySignal`) are read from the audio thread —
/// set them before `start()`.
public final class MicDetector: Detector {

    // MARK: - Detector conformance

    public let trigger: Trigger = .scream

    public var isEnabled: Bool

    public var onTriggerEvent: ((TriggerEvent) -> Void)?
    public var onIntensitySignal: ((IntensitySignal) -> Void)?

    // MARK: - Captured config

    private let config: ScreamConfig
    private let sampleRate: Double

    // MARK: - State

    private var voiceBandFilter: VoiceBandFilter
    private var processedSamples: Int = 0

    /// Sample index at which we most recently observed the level rising above
    /// threshold. `nil` means "currently below threshold" (or just reset
    /// after an emission).
    private var sustainStartSample: Int? = nil

    /// Engine-settable multiplier applied to this detector's effective
    /// threshold to implement the cross-trigger priming behaviour from
    /// `ARCHITECTURE.md`. Per `CONFIG_SCHEMA.md` line 86, the multiplier acts
    /// in RMS space — a value of `0.75` means "fire at 75% of the base RMS
    /// threshold," which translates to a dBFS offset of `20·log10(0.75) ≈
    /// -2.5 dB` on the detector's effective `dbfsThreshold`.
    ///
    /// Default is `1.0` (no priming — effective threshold equals base).
    /// Values in `[0.1, 1.0]` match the config schema's validation bounds.
    public var primingMultiplier: Double = 1.0

    // MARK: - AVAudioEngine ownership

    /// MicDetector owns its own `AVAudioEngine` instance. SoundEngine
    /// (Session 4) will own a separate engine for output. Apple's docs are
    /// fine with two engines per process; this matches the per-detector
    /// independence in ARCHITECTURE.md.
    private var audioEngine: AVAudioEngine?

    // MARK: - Init

    public init(config: ScreamConfig, sampleRate: Double = 44_100) {
        self.config = config
        self.sampleRate = sampleRate
        self.isEnabled = config.enabled
        self.voiceBandFilter = VoiceBandFilter(sampleRate: sampleRate)
    }

    // MARK: - Detector lifecycle

    /// Spin up an `AVAudioEngine`, hook the input node, install a tap that
    /// forwards buffers to `process(buffer:)`, and start the engine.
    /// Idempotent — calling twice replaces the previous setup.
    ///
    /// Doesn't request microphone permission. If the user has denied access,
    /// `engine.start()` succeeds but the tap delivers silence. Consumers
    /// should request mic permission before calling `start()`.
    public func start() throws {
        stop()

        // Resolve microphone permission with a hard timeout. Three cases
        // matter:
        //
        //   - already granted → callback fires immediately, true
        //   - already denied → callback fires immediately, false
        //   - notDetermined + interactive Terminal → TCC dialog appears,
        //     blocks until user responds, then callback fires
        //   - notDetermined + non-interactive (CI / launchd / agent
        //     contexts) → TCC dialog can't appear; callback may never
        //     fire. Without a timeout we'd hang on `engine.start()` later.
        //
        // 2 seconds is comfortably longer than any real prompt-and-grant
        // round trip but fast enough that a stuck non-interactive context
        // surfaces quickly.
        let granted = try Self.requestMicrophoneAccess(timeout: 2.0)
        if !granted {
            throw DetectorError.needsPrivilegedAccess(
                trigger: .scream,
                reason: "microphone access not granted (System Settings → Privacy & Security → Microphone)"
            )
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        do {
            try engine.start()
        } catch {
            throw DetectorError.inputSetupFailed(trigger: .scream, underlying: error.localizedDescription)
        }
        self.audioEngine = engine
    }

    public func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - Process (testable core)

    /// Primary detection entry point. Feed a mono Float32 PCM buffer; emits
    /// one `IntensitySignal` and possibly one `TriggerEvent`. Called from the
    /// audio-tap callback at runtime, or directly from tests with synthesised
    /// buffers.
    ///
    /// Skips processing entirely if `isEnabled == false`.
    func process(buffer: AVAudioPCMBuffer) {
        guard isEnabled else { return }
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Copy into a local array so filter mutation doesn't affect the caller's buffer.
        var samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        if config.voiceBandFilter {
            voiceBandFilter.apply(to: &samples)
        }

        let rms = computeRMS(samples)
        let dbfs = dbfsFromRMS(rms)

        let bufferStartSample = processedSamples
        processedSamples += frameCount
        let now = Date()

        let intensity = normalizedIntensity(fromDBFS: dbfs)
        onIntensitySignal?(IntensitySignal(value: intensity, timestamp: now))

        evaluateTrigger(dbfs: dbfs, intensity: intensity, bufferStartSample: bufferStartSample, now: now)

        precondition(
            retainedAudioSampleCount <= 8,
            "MicDetector retains \(retainedAudioSampleCount) samples, exceeding the 8-sample privacy invariant"
        )
    }

    // MARK: - Diagnostics (internal, for tests)

    /// Number of audio samples this detector currently holds between
    /// `process(buffer:)` calls. Must remain `<= 8` (biquad history) at all times.
    var retainedAudioSampleCount: Int {
        voiceBandFilter.retainedSampleCount
    }

    // MARK: - Permission resolution (testable seam)

    /// Resolve microphone permission with a hard timeout, returning `true`
    /// if granted. Throws `DetectorError.inputSetupFailed` if the request
    /// doesn't resolve within `timeout` seconds — a cue that the caller
    /// is in a non-interactive environment without TCC dialog support.
    ///
    /// `requestImpl` defaults to the real `AVCaptureDevice.requestAccess`
    /// but is overridable for tests so the timeout / granted / denied
    /// branches can be exercised without touching the system.
    static func requestMicrophoneAccess(
        timeout: TimeInterval,
        requestImpl: (@escaping (Bool) -> Void) -> Void = { handler in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: handler)
        }
    ) throws -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        // `granted` is written from the access-completion callback (any
        // queue) and read after `wait()` returns on this thread. The
        // semaphore enforces happens-before, so the read is safe without
        // explicit locking.
        var granted = false
        requestImpl { result in
            granted = result
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            throw DetectorError.inputSetupFailed(
                trigger: .scream,
                underlying: "microphone permission request timed out after \(timeout)s — likely a non-interactive environment without TCC support"
            )
        }
        return granted
    }

    // MARK: - Detection helpers

    private func computeRMS(_ samples: [Float]) -> Float {
        var sumSquared: Float = 0
        for s in samples {
            sumSquared += s * s
        }
        return sqrt(sumSquared / Float(samples.count))
    }

    private func dbfsFromRMS(_ rms: Float) -> Double {
        guard rms > 1e-10 else { return -200.0 }
        return 20.0 * log10(Double(rms))
    }

    private func normalizedIntensity(fromDBFS dbfs: Double) -> Double {
        let clipped = max(-60.0, min(0.0, dbfs))
        return (clipped + 60.0) / 60.0
    }

    private func evaluateTrigger(dbfs: Double, intensity: Double, bufferStartSample: Int, now: Date) {
        // Apply the priming multiplier to the base threshold. Multiplier acts
        // in RMS space (effective_rms = base_rms × mult); in dBFS that's an
        // additive offset of 20·log10(mult). Guard mult ≤ 0 even though
        // schema bounds prevent it.
        let effectiveThreshold: Double
        if primingMultiplier > 0 {
            effectiveThreshold = config.dbfsThreshold + 20.0 * log10(primingMultiplier)
        } else {
            effectiveThreshold = config.dbfsThreshold
        }

        guard dbfs >= effectiveThreshold else {
            sustainStartSample = nil
            return
        }

        if sustainStartSample == nil {
            sustainStartSample = bufferStartSample
        }

        let sustainSamples = processedSamples - (sustainStartSample ?? processedSamples)
        let sustainDuration = Double(sustainSamples) / sampleRate
        guard sustainDuration >= config.sustainSeconds else { return }

        // Sustain is met. Reset for the next emission window — without this,
        // every subsequent buffer above threshold would fire a redundant
        // event at audio-tap rate (~43 Hz). Resetting gives a natural
        // emission cadence of `sustainSeconds` during continuous loud audio.
        // The engine is responsible for cooldown-based filtering on top of
        // this.
        sustainStartSample = nil

        // wasPrimed is true iff the firing only happened because priming
        // lowered the threshold (dbfs below base, above primed). If the
        // signal was loud enough to trigger without priming, report false.
        let wasPrimed = dbfs < config.dbfsThreshold && dbfs >= effectiveThreshold

        onTriggerEvent?(TriggerEvent(
            trigger: .scream,
            timestamp: now,
            intensity: intensity,
            wasPrimed: wasPrimed
        ))
    }
}

// MARK: - Filter types

/// Single 2nd-order biquad filter using direct-form-I:
///
///     y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] - a1·y[n-1] - a2·y[n-2]
///
/// Coefficients are stored already-normalised by a0.
struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    /// Robert Bristow-Johnson cookbook coefficients for a Butterworth
    /// (Q = 1/√2) high-pass at `cutoff` Hz.
    static func butterworthHPF(cutoff: Double, sampleRate: Double) -> Biquad {
        let q = 1.0 / sqrt(2.0)
        let omega = 2.0 * .pi * cutoff / sampleRate
        let cosw = cos(omega)
        let alpha = sin(omega) / (2.0 * q)
        let a0 = 1.0 + alpha
        return Biquad(
            b0: Float((1.0 + cosw) / 2.0 / a0),
            b1: Float(-(1.0 + cosw) / a0),
            b2: Float((1.0 + cosw) / 2.0 / a0),
            a1: Float(-2.0 * cosw / a0),
            a2: Float((1.0 - alpha) / a0)
        )
    }

    /// RBJ cookbook coefficients for a Butterworth low-pass at `cutoff` Hz.
    static func butterworthLPF(cutoff: Double, sampleRate: Double) -> Biquad {
        let q = 1.0 / sqrt(2.0)
        let omega = 2.0 * .pi * cutoff / sampleRate
        let cosw = cos(omega)
        let alpha = sin(omega) / (2.0 * q)
        let a0 = 1.0 + alpha
        return Biquad(
            b0: Float((1.0 - cosw) / 2.0 / a0),
            b1: Float((1.0 - cosw) / a0),
            b2: Float((1.0 - cosw) / 2.0 / a0),
            a1: Float(-2.0 * cosw / a0),
            a2: Float((1.0 - alpha) / a0)
        )
    }

    mutating func apply(to samples: inout [Float]) {
        for i in 0..<samples.count {
            let x0 = samples[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            samples[i] = y0
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }
    }

    /// Audio samples retained as filter state: x1, x2, y1, y2.
    var retainedSampleCount: Int { 4 }
}

/// 200Hz-3kHz voice-band-pass, implemented as a Butterworth HPF @ 200Hz
/// cascaded with a Butterworth LPF @ 3kHz. Each is a 2nd-order biquad, so
/// the overall response rolls off at 12 dB/octave beyond each cutoff.
struct VoiceBandFilter {
    private(set) var hpf: Biquad
    private(set) var lpf: Biquad

    init(sampleRate: Double) {
        self.hpf = Biquad.butterworthHPF(cutoff: 200, sampleRate: sampleRate)
        self.lpf = Biquad.butterworthLPF(cutoff: 3000, sampleRate: sampleRate)
    }

    mutating func apply(to samples: inout [Float]) {
        hpf.apply(to: &samples)
        lpf.apply(to: &samples)
    }

    var retainedSampleCount: Int { hpf.retainedSampleCount + lpf.retainedSampleCount }
}
