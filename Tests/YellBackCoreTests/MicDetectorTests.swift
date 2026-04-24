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
///   - cooldown_seconds = 1.0 → 43+ buffers at 23ms/buffer.
final class MicDetectorTests: XCTestCase {

    // MARK: - Harness

    private final class Collector {
        var triggers: [TriggerEvent] = []
        var intensities: [(Trigger, IntensitySignal)] = []
    }

    private func makeDetector(
        _ config: ScreamConfig = ScreamConfig.default,
        sampleRate: Double = 44_100
    ) -> (MicDetector, Collector) {
        let c = Collector()
        let d = MicDetector(
            config: config,
            sampleRate: sampleRate,
            onTrigger: { c.triggers.append($0) },
            onIntensity: { c.intensities.append(($0, $1)) }
        )
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
        // Every intensity signal from pure silence should be effectively zero.
        for (_, sig) in c.intensities {
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

    func testSustainedLoudSineFiresSingleTrigger() throws {
        // Amplitude 0.5 → RMS ≈ 0.354 → dBFS ≈ -9 (well above -20). 1s is
        // above both 300ms sustain and 1s cooldown, but the trigger fires at
        // 300ms and the cooldown starts there — so only ONE trigger.
        let (d, c) = makeDetector()
        feed(d, AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 1_000))
        XCTAssertEqual(c.triggers.count, 1)
        let event = try XCTUnwrap(c.triggers.first)
        XCTAssertEqual(event.trigger, .scream)
        XCTAssertGreaterThan(event.intensity, 0.5, "loud sine should have high intensity")
        XCTAssertFalse(event.wasPrimed, "detector never sees priming state directly")
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

    // MARK: - Cooldown

    func testCooldownBlocksImmediateRetrigger() throws {
        // scream 500ms → trigger. Gap 200ms (< 1s cooldown). Scream 500ms again.
        // Only the first should fire; the second falls inside cooldown.
        let (d, c) = makeDetector()
        let seq = AudioFixtures.concat([
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 500),
            AudioFixtures.silence(durationMs: 200),
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 500)
        ])
        feed(d, seq)
        XCTAssertEqual(c.triggers.count, 1)
    }

    func testCooldownExpiryAllowsRetrigger() throws {
        // scream → trigger. Gap 1200ms (> 1s cooldown). Scream again → trigger.
        let (d, c) = makeDetector()
        let seq = AudioFixtures.concat([
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 500),
            AudioFixtures.silence(durationMs: 1_200),
            AudioFixtures.sine(frequency: 1_000, amplitude: 0.5, durationMs: 500)
        ])
        feed(d, seq)
        XCTAssertEqual(c.triggers.count, 2)
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
        // should trigger.
        let config = try ScreamConfig(voiceBandFilter: false)
        let (d, c) = makeDetector(config)
        feed(d, AudioFixtures.sine(frequency: 50, amplitude: 0.5, durationMs: 1_000))
        XCTAssertEqual(c.triggers.count, 1, "with voiceBandFilter=false, 50Hz should reach RMS unfiltered and trigger")
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
        XCTAssertTrue(c.intensities.allSatisfy { $0.0 == .scream }, "MicDetector only emits .scream intensities")
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
