import Foundation
import AVFoundation

/// Microphone-based scream detector.
///
/// Consumes `AVAudioPCMBuffer`s of mono Float32 samples, optionally applies a
/// 200Hz-3kHz Butterworth band-pass (cascade of two 2nd-order biquads), and
/// computes RMS-based dBFS per buffer. Emits:
///
///   - A continuous `IntensitySignal` every `process(buffer:)` call, regardless
///     of threshold — consumed by v2 fusion; v1 consumers may ignore.
///   - A discrete `TriggerEvent` when dBFS has stayed at or above
///     `ScreamConfig.dbfsThreshold` for at least `sustainSeconds` and the
///     `cooldownSeconds` since the last firing has elapsed.
///
/// ## Privacy invariant
///
/// `MicDetector` retains no audio samples between `process(buffer:)` calls
/// beyond the **8 samples** of biquad filter history (two 2nd-order sections
/// × four samples of state each). A debug-build `precondition` fires if any
/// change causes `retainedAudioSampleCount` to exceed 8. This is the mechanism
/// that enforces the architectural promise that this detector reads level
/// only — never buffers, records, or transmits audio.
///
/// ## Timekeeping
///
/// Sustain and cooldown logic use a sample-accurate monotonic clock computed
/// as `processedSamples / sampleRate`. This gives deterministic, identical
/// behavior whether buffers arrive from a live audio tap or from synthetic
/// test fixtures. `TriggerEvent.timestamp` uses wall-clock `Date()` so
/// consumers can render human-readable timestamps.
///
/// ## Threading
///
/// `process(buffer:)` is expected to be called from a single thread —
/// typically the audio-tap callback thread. `start(on:)` / `stop()` are
/// expected to be called from one other thread (the engine's lifecycle
/// thread). The detector does no internal locking; callers are responsible
/// for serialising access if they do something unusual.
///
/// ## Sample rate
///
/// Biquad coefficients are computed once at init for the configured
/// `sampleRate`. Buffers fed to `process(buffer:)` must share that rate.
/// Mismatched rates will not crash but will produce subtly incorrect
/// filtering and timing. When using `start(on:)`, initialise the detector
/// with the input node's native rate.
final class MicDetector {

    // MARK: - Captured config

    private let config: ScreamConfig
    private let sampleRate: Double

    // MARK: - Callbacks

    private let onTrigger: (TriggerEvent) -> Void
    private let onIntensity: (Trigger, IntensitySignal) -> Void

    // MARK: - State

    private var voiceBandFilter: VoiceBandFilter
    private var processedSamples: Int = 0

    /// Sample index at which we most recently observed the level rising above
    /// threshold. `nil` means "currently below threshold" (or just reset).
    private var sustainStartSample: Int? = nil

    /// Sample index of the most recent trigger firing. `nil` means "never
    /// fired this session."
    private var lastTriggerSample: Int? = nil

    /// Engine-settable multiplier applied to this detector's effective
    /// threshold to implement the cross-trigger priming behaviour from
    /// `ARCHITECTURE.md`. Per `CONFIG_SCHEMA.md` line 86, the multiplier acts
    /// in RMS space — a value of `0.75` means "fire at 75% of the base RMS
    /// threshold," which translates to a dBFS offset of `20·log10(0.75) ≈
    /// -2.5 dB` on the detector's effective `dbfsThreshold`.
    ///
    /// Default is `1.0` (no priming — effective threshold equals base).
    /// Values in `[0.1, 1.0]` match the config schema's validation bounds.
    /// Session 3 ships this hook; Session 5 wires `YellBackEngine` to set it
    /// when its owned `PrimingState` transitions.
    ///
    /// Concurrency: the engine is expected to write this between audio-tap
    /// callbacks; `process(buffer:)` reads it. The race is benign (at worst
    /// one buffer uses a stale multiplier) so no lock is taken.
    var primingMultiplier: Double = 1.0

    // MARK: - Tap state (live-audio convenience)

    private weak var attachedNode: AVAudioInputNode?

    // MARK: - Init

    init(
        config: ScreamConfig,
        sampleRate: Double = 44_100,
        onTrigger: @escaping (TriggerEvent) -> Void,
        onIntensity: @escaping (Trigger, IntensitySignal) -> Void
    ) {
        self.config = config
        self.sampleRate = sampleRate
        self.onTrigger = onTrigger
        self.onIntensity = onIntensity
        self.voiceBandFilter = VoiceBandFilter(sampleRate: sampleRate)
    }

    // MARK: - Process

    /// Primary entry point. Feed this a mono Float32 PCM buffer. Always emits
    /// one `IntensitySignal`; additionally emits one `TriggerEvent` iff the
    /// sustain and cooldown conditions are both met for this buffer.
    func process(buffer: AVAudioPCMBuffer) {
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
        onIntensity(.scream, IntensitySignal(value: intensity, timestamp: now))

        evaluateTrigger(dbfs: dbfs, intensity: intensity, bufferStartSample: bufferStartSample, now: now)

        // Privacy invariant: 8 = biquad state (4 samples × 2 sections). Any growth
        // here means someone added audio-buffering state — violate the promise.
        precondition(
            retainedAudioSampleCount <= 8,
            "MicDetector retains \(retainedAudioSampleCount) samples, exceeding the 8-sample privacy invariant"
        )
    }

    // MARK: - Diagnostics (internal, for tests)

    /// Number of audio samples this detector currently holds between process
    /// calls. Must remain <= 8 (biquad history) at all times.
    var retainedAudioSampleCount: Int {
        voiceBandFilter.retainedSampleCount
    }

    // MARK: - Live-audio convenience

    /// Install an audio tap on `inputNode` that feeds `process(buffer:)`.
    /// Idempotent — calling twice replaces the tap.
    ///
    /// Not exercised by unit tests (would require mic permission and a
    /// running AVAudioEngine). Session 5 wires this through YellBackEngine;
    /// until then, consumers feed `process(buffer:)` directly.
    func start(on inputNode: AVAudioInputNode) {
        stop()
        let format = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        attachedNode = inputNode
    }

    func stop() {
        attachedNode?.removeTap(onBus: 0)
        attachedNode = nil
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
        // Guard against log10(0). Anything below ~1e-10 is effectively silence.
        guard rms > 1e-10 else { return -200.0 }
        return 20.0 * log10(Double(rms))
    }

    /// Map dBFS to a 0..1 intensity signal, linear in dB, clipped at -60 and 0.
    private func normalizedIntensity(fromDBFS dbfs: Double) -> Double {
        let clipped = max(-60.0, min(0.0, dbfs))
        return (clipped + 60.0) / 60.0
    }

    private func evaluateTrigger(dbfs: Double, intensity: Double, bufferStartSample: Int, now: Date) {
        // Apply the priming-state multiplier to the base threshold. In RMS
        // space the multiplier is literal (effective_rms = base_rms × mult);
        // in dBFS space that becomes an additive offset of 20·log10(mult).
        // Guard multiplier <= 0 even though schema bounds prevent it — log10
        // of a non-positive is undefined.
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

        // This buffer's level is above the (possibly primed) threshold. If we
        // were below-threshold before, mark the start of this buffer as the
        // beginning of sustain.
        if sustainStartSample == nil {
            sustainStartSample = bufferStartSample
        }

        let sustainSamples = processedSamples - (sustainStartSample ?? processedSamples)
        let sustainDuration = Double(sustainSamples) / sampleRate
        guard sustainDuration >= config.sustainSeconds else { return }

        if let last = lastTriggerSample {
            let elapsedSinceLast = Double(processedSamples - last) / sampleRate
            guard elapsedSinceLast >= config.cooldownSeconds else { return }
        }

        lastTriggerSample = processedSamples
        // Reset sustain so the next trigger requires another full sustain
        // window to accumulate from scratch (see ARCHITECTURE.md's priming
        // rationale — continuous loud audio fires once per cooldown period,
        // not once per sustain period).
        sustainStartSample = nil

        // `wasPrimed` is true iff the firing only happened because priming
        // lowered the threshold — i.e. dbfs was below base but above the
        // primed effective threshold. If the signal was loud enough to
        // trigger without priming, report `false`.
        let wasPrimed = dbfs < config.dbfsThreshold && dbfs >= effectiveThreshold

        onTrigger(TriggerEvent(
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
