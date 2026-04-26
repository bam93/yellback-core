import XCTest
import AVFoundation
@testable import YellBackCore

/// Unit tests for `MicDetector`. All inputs are synthesised via `AudioFixtures`;
/// no real microphone or AVAudioEngine involvement. Buffers are fed to
/// `process(buffer:)` in ~23ms slices to mimic the live input-tap cadence.
///
/// Numeric reference (44.1kHz mono, default `ScreamConfig`):
///   - dbfs_threshold = -20 dBFS → RMS threshold of 0.1 → sine of amplitude
///     0.1·√2 ≈ 0.1414 sits exactly on the boundary.
///   - sustain_seconds = 0.3 → 13.2 buffers at 23ms/buffer.
///   - cooldown_seconds is in `ScreamConfig` for engine-level use; **the
///     detector itself does NOT enforce it.** Continuous loud audio fires
///     events at sustain cadence (~3.3 Hz for the default 0.3s sustain).
final class MicDetectorTests: XCTestCase {

    // MARK: - Harness

    private final class Collector {
        var triggers: [TriggerEvent] = []
        var intensities: [IntensitySignal] = []
    }

    private func makeDetector(
        _ config: ScreamConfig = ScreamConfig.default,
        sampleRate: Double = 44_100
    ) -> (MicDetector, Collector) {
        let c = Collector()
        let d = MicDetector(config: config, sampleRate: sampleRate)
        d.onTriggerEvent = { c.triggers.append($0) }
        d.onIntensitySignal = { c.intensities.append($0) }
        return (d, c)
    }

    /// Feed a buffer to the detector in 23ms slices — the live-tap cadence.
    private func feed(_ detector: MicDetector, _ buffer: AVAudioPCMBuffer, chunkMs: Int = 23) {
        for chunk in AudioFixtures.chunk(buffer, intoChunksOfMs: chunkMs) {
            detector.process(buffer: chunk)
        }
    }

    // MARK: - Silence & sub-threshold

    func testSilenceProducesNoTriggers() throws {
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.silence(durationMs: 5_000))
        XCTAssertEqual(c.triggers.count, 0)
        for sig in c.intensities {
            XCTAssertLessThan(sig.value, 0.01, "silence should produce near-zero intensity")
        }
    }

    func testSubThresholdAmplitudeDoesNotTrigger() throws {
        // Amplitude 0.13 → RMS ≈ 0.092 → dBFS ≈ -20.7 (below -20 threshold)
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.13, durationMs: 1_000))
        XCTAssertEqual(c.triggers.count, 0)
    }

    // MARK: - Happy path

    func testShortLoudClipFiresSingleTriggerWithExpectedPayload() throws {
        // Amplitude 0.5 → RMS ≈ 0.354 → dBFS ≈ -9 (well above -20).
        // 400ms is long enough for sustain (300ms) to fire exactly once
        // (the post-emission sustain reset doesn't reach 300ms again
        // before the clip ends).
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 400))
        XCTAssertEqual(c.triggers.count, 1)
        let event = try XCTUnwrap(c.triggers.first)
        XCTAssertEqual(event.trigger, .scream)
        XCTAssertGreaterThan(event.intensity, 0.5, "loud sine should have high intensity")
        XCTAssertFalse(event.wasPrimed, "default primingMultiplier=1.0 → wasPrimed=false")
    }

    func testContinuousLoudAudioFiresAtSustainCadence() throws {
        // 1000ms of continuous loud sine. With sustain=0.3s and no
        // detector-level cooldown, sustain resets after each emission so
        // emissions occur every ~300ms. 1s should produce ~3 triggers
        // (at t≈0.3s, 0.6s, 0.9s). The engine's cooldown filter
        // (Session 5) is what reduces this to a single playback per
        // cooldown window.
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 1_000))
        XCTAssertEqual(
            c.triggers.count, 3,
            "continuous loud at sustain=0.3s should fire ~3 times in 1s — engine handles rate limiting"
        )
    }

    func testBriefLoudSpikeDoesNotTrigger() throws {
        // 100ms of loud — well below 300ms sustain.
        let (d, c) = makeDetector()
        let spike = AudioFixtures.concat([
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 100),
            AudioFixtures.silence(durationMs: 500)
        ])
        feed(d, spike)
        XCTAssertEqual(c.triggers.count, 0)
    }

    // MARK: - dBFS threshold boundary (Session 2.5 testing bar)

    func testAmplitudeJustAboveDbfsThresholdTriggers() throws {
        // Amplitude 0.16 → RMS ≈ 0.113 → dBFS ≈ -18.9 (comfortably above -20)
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.16, durationMs: 500))
        XCTAssertEqual(c.triggers.count, 1)
    }

    func testAmplitudeJustBelowDbfsThresholdDoesNotTrigger() throws {
        // Amplitude 0.12 → RMS ≈ 0.085 → dBFS ≈ -21.4 (comfortably below -20)
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.12, durationMs: 500))
        XCTAssertEqual(c.triggers.count, 0)
    }

    // MARK: - Sustain boundary

    func testSustainJustBelowDoesNotTrigger() throws {
        // 280ms of loud sine — just short of the 300ms sustain threshold.
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 280))
        XCTAssertEqual(c.triggers.count, 0)
    }

    func testSustainJustAboveTriggers() throws {
        // 330ms of loud sine — comfortably above the 300ms sustain threshold,
        // but not so much above that a test clock drift could mask a regression.
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 330))
        XCTAssertEqual(c.triggers.count, 1)
    }

    func testIntermittentLoudAudioDoesNotAccumulateSustain() throws {
        // 150ms loud + 150ms silent + 150ms loud + 150ms silent + 150ms loud.
        // Total above-threshold time is 450ms but NEVER continuous for 300ms.
        // Must not trigger — sustain resets each time level drops.
        let (d, c) = makeDetector()
        let pattern = AudioFixtures.concat([
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 150),
            AudioFixtures.silence(durationMs: 150),
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 150),
            AudioFixtures.silence(durationMs: 150),
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 150)
        ])
        feed(d, pattern)
        XCTAssertEqual(c.triggers.count, 0, "sustain must be continuous; intermittent loud must not accumulate")
    }

    // MARK: - No detector-level cooldown (engine owns cooldown)

    func testTwoCloseScreamsBothFireRegardlessOfShortGap() throws {
        // Two 400ms screams separated by 100ms silence. The engine would
        // (Session 5) suppress the second under default 1s cooldown; the
        // detector itself does not. Asserts the contract: detector emits
        // raw events, doesn't filter.
        let (d, c) = makeDetector()
        let seq = AudioFixtures.concat([
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 400),
            AudioFixtures.silence(durationMs: 100),
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 400)
        ])
        feed(d, seq)
        XCTAssertEqual(
            c.triggers.count, 2,
            "no detector-level cooldown: both screams fire (engine handles rate limiting)"
        )
    }

    // MARK: - Voice band filter

    func testVoiceBandFilterRejectsSubBassRumble() throws {
        // 50Hz tone at amplitude 0.5 — would be loud unfiltered (well above
        // threshold). With the 200Hz HPF active (voiceBandFilter=true default),
        // the 50Hz content is attenuated and shouldn't trigger.
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 50, amplitude: 0.5, durationMs: 1_000))
        XCTAssertEqual(c.triggers.count, 0, "50Hz rumble should be rejected by the 200Hz HPF")
    }

    func testVoiceBandFilterRejectsUltrasonic() throws {
        // 10kHz tone at amplitude 0.5 — above the 3kHz LPF cutoff, should be
        // attenuated enough not to trigger.
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 10_000, amplitude: 0.5, durationMs: 1_000))
        XCTAssertEqual(c.triggers.count, 0, "10kHz tone should be rejected by the 3kHz LPF")
    }

    func testVoiceBandFilterDisabledAcceptsOutOfBandEnergy() throws {
        // Same 50Hz tone, but with the voice-band filter explicitly disabled
        // via config. RMS measurement sees the full unfiltered signal and
        // should trigger. (Without the filter, 1s of continuous loud 50Hz
        // fires at sustain cadence — the number matches continuous-loud
        // behavior, i.e. >= 1 trigger is the relevant assertion.)
        let config = try ScreamConfig(voiceBandFilter: false)
        let (d, c) = makeDetector(config)
        feed(d, AudioFixtures.sine(frequency: 50, amplitude: 0.5, durationMs: 1_000))
        XCTAssertGreaterThanOrEqual(
            c.triggers.count, 1,
            "with voiceBandFilter=false, 50Hz should reach RMS unfiltered and trigger at least once"
        )
    }

    // MARK: - Priming hook (engine-settable threshold multiplier)

    func testPrimingMultiplierLowersEffectiveThresholdAndSetsWasPrimed() throws {
        // Amplitude 0.11 → RMS ≈ 0.0778 → dBFS ≈ -22.2, which is BELOW the
        // base threshold of -20 (would not trigger unprimed — verified by
        // the existing testAmplitudeJustBelowDbfsThresholdDoesNotTrigger).
        //
        // With primingMultiplier = 0.75, the effective threshold becomes
        // -20 + 20·log10(0.75) ≈ -22.5, so -22.2 is above effective → triggers.
        let (d, c) = makeDetector()
        d.primingMultiplier = 0.75
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.11, durationMs: 500))
        XCTAssertEqual(c.triggers.count, 1, "priming should lower threshold enough for amplitude 0.11 to trigger")
        XCTAssertTrue(
            try XCTUnwrap(c.triggers.first).wasPrimed,
            "firing that only happened because of priming must carry wasPrimed=true"
        )
    }

    func testPrimingMultiplierDoesNotSetWasPrimedWhenFiringWouldHaveHappenedAnyway() throws {
        // Amplitude 0.5 → dBFS ≈ -9, well above both base (-20) and
        // primed-at-0.75 (-22.5). Priming didn't affect whether this fires.
        let (d, c) = makeDetector()
        d.primingMultiplier = 0.75
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 500))
        XCTAssertEqual(c.triggers.count, 1)
        XCTAssertFalse(
            try XCTUnwrap(c.triggers.first).wasPrimed,
            "a firing that would have happened without priming must carry wasPrimed=false"
        )
    }

    // MARK: - Intensity signal

    func testIntensitySignalEmittedExactlyOncePerBuffer() throws {
        let (d, c) = makeDetector()
        let buffer = AudioFixtures.silence(durationMs: 500)
        let chunks = AudioFixtures.chunk(buffer, intoChunksOfMs: 23)
        for chunk in chunks {
            d.process(buffer: chunk)
        }
        XCTAssertEqual(c.intensities.count, chunks.count, "one intensity signal per process() call")
    }

    // MARK: - Microphone permission resolution

    /// Tests for `MicDetector.requestMicrophoneAccess(timeout:requestImpl:)`
    /// — the seam introduced to keep `start()` from hanging in non-
    /// interactive environments where TCC dialogs can't appear. Real
    /// AVCaptureDevice is mocked via the `requestImpl` parameter; the
    /// timeout / granted / denied branches are exercised in isolation
    /// so we don't need a Mac with real TCC state to test them.

    func testRequestMicrophoneAccessReturnsTrueWhenImmediatelyGranted() throws {
        let granted = try MicDetector.requestMicrophoneAccess(timeout: 1.0) { handler in
            handler(true)
        }
        XCTAssertTrue(granted)
    }

    func testRequestMicrophoneAccessReturnsFalseWhenImmediatelyDenied() throws {
        let granted = try MicDetector.requestMicrophoneAccess(timeout: 1.0) { handler in
            handler(false)
        }
        XCTAssertFalse(granted)
    }

    func testRequestMicrophoneAccessThrowsInputSetupFailedOnTimeout() {
        // Simulate a non-interactive context where the TCC dialog never
        // appears and the completion handler is never invoked. The
        // underlying message should mention the timeout duration so a
        // user grepping for "timed out" finds it.
        XCTAssertThrowsError(
            try MicDetector.requestMicrophoneAccess(timeout: 0.05) { _ in
                // never call the handler
            }
        ) { error in
            guard case DetectorError.inputSetupFailed(let trigger, let underlying) = error else {
                XCTFail("expected .inputSetupFailed, got \(error)")
                return
            }
            XCTAssertEqual(trigger, .scream)
            XCTAssertTrue(underlying.contains("timed out"), "underlying message should mention the timeout for grep-ability; got: \(underlying)")
        }
    }

    func testRequestMicrophoneAccessHonoursAsyncCallback() throws {
        // The completion can fire from any queue. Verify the semaphore-
        // based wait correctly hands the result back when the completion
        // is dispatched asynchronously rather than called synchronously.
        let granted = try MicDetector.requestMicrophoneAccess(timeout: 1.0) { handler in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                handler(true)
            }
        }
        XCTAssertTrue(granted)
    }

    // MARK: - isEnabled gate (Detector protocol)

    func testIsEnabledFalseSuppressesAllCallbacks() throws {
        let (d, c) = makeDetector()
        d.isEnabled = false
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 1_000))
        XCTAssertEqual(c.triggers.count, 0, "isEnabled=false: no trigger events")
        XCTAssertEqual(c.intensities.count, 0, "isEnabled=false: no intensity signals either")
    }

    func testIsEnabledDefaultsToConfigEnabledFlag() throws {
        let enabledConfig = try ScreamConfig(enabled: true)
        let disabledConfig = try ScreamConfig(enabled: false)
        XCTAssertTrue(MicDetector(config: enabledConfig).isEnabled)
        XCTAssertFalse(MicDetector(config: disabledConfig).isEnabled)
    }

    // MARK: - Privacy invariant

    func testRetainedAudioSampleCountNeverExceedsEight() throws {
        let (d, _) = makeDetector()
        // 10 seconds of audio in ~23ms chunks is ~434 process() calls.
        // The precondition inside process() would fire if retention grew, but
        // we also assert the post-condition explicitly for loud documentation.
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.3, durationMs: 10_000))
        XCTAssertEqual(d.retainedAudioSampleCount, 8, "two biquad sections × 4 samples of history each = 8")
    }
}
