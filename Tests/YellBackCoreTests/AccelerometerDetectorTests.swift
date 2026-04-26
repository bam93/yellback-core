import XCTest
import IOKit
@testable import YellBackCore

/// Unit tests for `AccelerometerDetector`.
///
/// All inputs are synthesised via `MotionFixtures` or direct construction;
/// no real accelerometer required. The `IOKit`-based `start()` /`stop()`
/// integration is exercised only manually via `sudo yellback --listen` —
/// CI can't reliably assert on its outcome (depends on running-as-root and
/// whether the host Mac has the sensor).
///
/// Numeric reference (default `DeskBangConfig`):
///   - `gForceThreshold = 1.5` g (delta from 1g gravity baseline)
///   - A sample at z=2.5 produces magnitude 2.5, delta 1.5 → exactly at threshold.
final class AccelerometerDetectorTests: XCTestCase {

    // MARK: - Harness

    private final class Collector {
        var triggers: [TriggerEvent] = []
        var intensities: [IntensitySignal] = []
    }

    private func makeDetector(
        _ config: DeskBangConfig = DeskBangConfig.default
    ) -> (AccelerometerDetector, Collector) {
        let c = Collector()
        let d = AccelerometerDetector(config: config)
        d.onTriggerEvent = { c.triggers.append($0) }
        d.onIntensitySignal = { c.intensities.append($0) }
        return (d, c)
    }

    private func feed(_ detector: AccelerometerDetector, _ samples: [AccelerometerSample]) {
        for s in samples { detector.process(sample: s) }
    }

    // MARK: - Rest & sub-threshold

    func testRestingMacDoesNotTrigger() throws {
        let (d, c) = makeDetector()
        feed(d, MotionFixtures.stillFor(durationMs: 2_000))
        XCTAssertEqual(c.triggers.count, 0)
        for sig in c.intensities {
            XCTAssertLessThan(sig.value, 0.01, "resting Mac should produce ~0 intensity")
        }
    }

    func testSubThresholdTapDoesNotTrigger() throws {
        // Magnitude 2.0 → delta 1.0 (below default 1.5 threshold).
        let (d, c) = makeDetector()
        feed(d, [MotionFixtures.sample(gForceMagnitude: 2.0)])
        XCTAssertEqual(c.triggers.count, 0)
    }

    // MARK: - Happy path

    func testSharpTapTriggers() throws {
        let (d, c) = makeDetector()
        feed(d, [MotionFixtures.sample(gForceMagnitude: 3.0)])
        XCTAssertEqual(c.triggers.count, 1)
        let event = try XCTUnwrap(c.triggers.first)
        XCTAssertEqual(event.trigger, .deskBang)
        XCTAssertGreaterThan(event.intensity, 0.5, "2g delta should map to intensity > 0.5")
        XCTAssertFalse(event.wasPrimed, "default primingMultiplier=1.0 → wasPrimed=false")
    }

    func testStillSequenceWithSingleTapFiresOneTrigger() throws {
        let (d, c) = makeDetector()
        feed(d, MotionFixtures.stillWithSingleTap(
            gForceMagnitude: 3.0,
            tapAtMs: 1_000,
            totalDurationMs: 2_000
        ))
        XCTAssertEqual(c.triggers.count, 1)
    }

    // MARK: - G-force threshold boundaries (Session 2.5 bar)

    func testGForceDeltaAtThresholdTriggers() throws {
        // Magnitude 2.5 → delta exactly 1.5 → at threshold → fires (>= check).
        let (d, c) = makeDetector()
        feed(d, [MotionFixtures.sample(gForceMagnitude: 2.5)])
        XCTAssertEqual(c.triggers.count, 1, "delta exactly at threshold should trigger (>=)")
    }

    func testGForceDeltaJustBelowThresholdDoesNotTrigger() throws {
        let (d, c) = makeDetector()
        feed(d, [MotionFixtures.sample(gForceMagnitude: 2.49)])
        XCTAssertEqual(c.triggers.count, 0)
    }

    func testGForceDeltaJustAboveThresholdTriggers() throws {
        let (d, c) = makeDetector()
        feed(d, [MotionFixtures.sample(gForceMagnitude: 2.51)])
        XCTAssertEqual(c.triggers.count, 1)
    }

    // MARK: - 1g baseline handling

    func testAbsoluteOneGReadingDoesNotTriggerBecauseItIsRest() throws {
        // If the detector mistakenly used absolute magnitude instead of
        // delta-from-gravity, resting (magnitude = 1g) would trigger.
        // Pins the delta-from-gravity semantics.
        let (d, c) = makeDetector()
        feed(d, [MotionFixtures.sample(gForceMagnitude: 1.0)])
        XCTAssertEqual(c.triggers.count, 0, "1g absolute IS rest — must not trigger")
    }

    func testNegativeAxisWithMagnitudeOneIsAlsoRest() throws {
        // Upside-down or tilted Mac: z=-1, magnitude=1 → delta from 1g = 0.
        let (d, c) = makeDetector()
        d.process(sample: AccelerometerSample(x: 0, y: 0, z: -1.0, timestamp: 0))
        XCTAssertEqual(c.triggers.count, 0, "magnitude=1 (any orientation) is rest")
    }

    // MARK: - Priming hook

    func testPrimingMultiplierLowersEffectiveThresholdAndSetsWasPrimed() throws {
        // Magnitude 2.2 → delta 1.2, below base 1.5. With multiplier 0.75,
        // effective threshold = 1.5 × 0.75 = 1.125 → 1.2 > 1.125 → fires.
        let (d, c) = makeDetector()
        d.primingMultiplier = 0.75
        feed(d, [MotionFixtures.sample(gForceMagnitude: 2.2)])
        XCTAssertEqual(c.triggers.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(c.triggers.first).wasPrimed,
            "firing that only happened because of priming must carry wasPrimed=true"
        )
    }

    func testPrimingMultiplierDoesNotSetWasPrimedWhenFiringWouldHaveHappenedAnyway() throws {
        // Magnitude 5g → delta 4, way above both base (1.5) and primed (1.125).
        let (d, c) = makeDetector()
        d.primingMultiplier = 0.75
        feed(d, [MotionFixtures.sample(gForceMagnitude: 5.0)])
        XCTAssertEqual(c.triggers.count, 1)
        XCTAssertFalse(try XCTUnwrap(c.triggers.first).wasPrimed)
    }

    // MARK: - isEnabled gate

    func testIsEnabledFalseSuppressesAllCallbacks() throws {
        let (d, c) = makeDetector()
        d.isEnabled = false
        feed(d, [MotionFixtures.sample(gForceMagnitude: 3.0)])
        XCTAssertEqual(c.triggers.count, 0)
        XCTAssertEqual(c.intensities.count, 0)
    }

    func testIsEnabledDefaultsToConfigEnabledFlag() throws {
        XCTAssertTrue(AccelerometerDetector(config: try DeskBangConfig(enabled: true)).isEnabled)
        XCTAssertFalse(AccelerometerDetector(config: try DeskBangConfig(enabled: false)).isEnabled)
    }

    // MARK: - HID report parsing (pure function, no IOKit)

    /// Build a 22-byte HID report with X/Y/Z at the Q16.16 fixed-point
    /// offsets the driver produces (bytes 6/10/14 as int32 LE).
    private func makeReport(x: Double, y: Double, z: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 22)
        func writeInt32(_ value: Int32, at offset: Int) {
            let le = value.littleEndian
            bytes[offset + 0] = UInt8(truncatingIfNeeded: le)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: le >> 8)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: le >> 16)
            bytes[offset + 3] = UInt8(truncatingIfNeeded: le >> 24)
        }
        writeInt32(Int32(x * 65536.0), at: 6)
        writeInt32(Int32(y * 65536.0), at: 10)
        writeInt32(Int32(z * 65536.0), at: 14)
        return bytes
    }

    func testParseReportExtractsCorrectGForceValuesFromQ1616FixedPoint() throws {
        // Rest sample: 0, 0, 1.0 g.
        let report = makeReport(x: 0, y: 0, z: 1.0)
        let sample = try report.withUnsafeBufferPointer { buf -> AccelerometerSample in
            try XCTUnwrap(AccelerometerDetector.parseReport(buf.baseAddress!, length: buf.count))
        }
        XCTAssertEqual(sample.x, 0, accuracy: 1e-6)
        XCTAssertEqual(sample.y, 0, accuracy: 1e-6)
        XCTAssertEqual(sample.z, 1.0, accuracy: 1e-4, "Q16.16 scale should round-trip within quantisation")
    }

    func testParseReportExtractsNegativeValues() throws {
        // Sideways orientation: x=-1g, y=0, z=0.
        let report = makeReport(x: -1.0, y: 0, z: 0)
        let sample = try report.withUnsafeBufferPointer { buf -> AccelerometerSample in
            try XCTUnwrap(AccelerometerDetector.parseReport(buf.baseAddress!, length: buf.count))
        }
        XCTAssertEqual(sample.x, -1.0, accuracy: 1e-4)
        XCTAssertEqual(sample.y, 0, accuracy: 1e-6)
        XCTAssertEqual(sample.z, 0, accuracy: 1e-6)
    }

    func testParseReportRejectsUndersizedReport() throws {
        // Fewer than 18 bytes (offset 14 + 4) should return nil, not a
        // zero-filled garbage sample.
        let shortReport = [UInt8](repeating: 0, count: 10)
        shortReport.withUnsafeBufferPointer { buf in
            XCTAssertNil(
                AccelerometerDetector.parseReport(buf.baseAddress!, length: buf.count),
                "undersized report must return nil"
            )
        }
    }

    func testParsedReportFedIntoProcessFiresTriggerForLoudTap() throws {
        // Full round-trip: build a loud-impact report, parse it, feed into
        // the detector, expect a trigger. Exercises the real data path that
        // the IOKit callback uses.
        let (d, c) = makeDetector()
        let report = makeReport(x: 0, y: 0, z: 3.0) // 2g delta → well above 1.5
        let sample = try report.withUnsafeBufferPointer { buf -> AccelerometerSample in
            try XCTUnwrap(AccelerometerDetector.parseReport(buf.baseAddress!, length: buf.count))
        }
        d.process(sample: sample)
        XCTAssertEqual(c.triggers.count, 1)
    }

    // MARK: - Privacy invariant

    func testRetainedMotionSampleCountStaysZeroAfterManySamples() throws {
        // Pin the contract: AccelerometerDetector retains no motion data
        // between process() calls. The runtime precondition inside
        // process() catches any future contributor adding rolling-buffer
        // state; this test asserts the post-condition explicitly. Mirrors
        // MicDetector's testRetainedAudioSampleCountNeverExceedsEight.
        let (d, _) = makeDetector()
        XCTAssertEqual(d.retainedMotionSampleCount, 0, "starts at zero")
        for i in 0..<5_000 {
            // Mix of rest, sub-threshold, and trigger-eligible samples to
            // exercise both branches of the guard inside process().
            let mag = (i % 100 == 0) ? 3.0 : 1.0 + Double(i % 7) * 0.05
            d.process(sample: MotionFixtures.sample(gForceMagnitude: mag, at: TimeInterval(i)))
        }
        XCTAssertEqual(d.retainedMotionSampleCount, 0, "still zero after 5000 process() calls")
    }

    // MARK: - SPU wake property drift (catches accidental rename)

    func testSPUDriverServiceNameIsLockedToAppleSPUHIDDriver() {
        // If anyone changes this string, the wake step silently no-ops on
        // M2/M3/M4 and desk_bang stops firing. Pin the literal name so a
        // typo or refactor fails loudly. Note: this catches LOCAL drift
        // (someone editing the constant); it does not catch Apple renaming
        // the underlying IOKit class in a future macOS release — that's
        // a manual-verification problem.
        XCTAssertEqual(AccelerometerDetector.spuDriverServiceName, "AppleSPUHIDDriver")
    }

    func testSPUWakePropertiesAreLockedToTheThreeKnownToWorkOnM2() {
        let props = AccelerometerDetector.spuWakeProperties
        XCTAssertEqual(props.count, 3, "exactly three wake properties — M2 is silent without all of them")

        XCTAssertEqual(props[0].key, "SensorPropertyReportingState")
        XCTAssertEqual(props[0].value, 1)
        XCTAssertEqual(props[1].key, "SensorPropertyPowerState")
        XCTAssertEqual(props[1].value, 1)
        XCTAssertEqual(props[2].key, "ReportInterval")
        XCTAssertEqual(props[2].value, 1000, "1000 microseconds → 1 kHz; raising weakens the signal, lowering may oversample")
    }

    // MARK: - Start-error derivation (pure function, no IOKit)

    func testDeriveStartErrorReturnsNilOnSuccessfulOpenWithDevices() {
        let result = AccelerometerDetector.deriveStartError(openResult: kIOReturnSuccess, deviceCount: 1)
        XCTAssertNil(result, "successful open + ≥1 device → no error")
    }

    func testDeriveStartErrorReturnsHardwareUnavailableOnEmptyDeviceSet() {
        // The "Mac mini / Mac Studio / base M1" case: open succeeds, but no
        // matching SPU sensor exists. This is the path my Session-3+7
        // landing claimed to handle but had zero tests for.
        let result = AccelerometerDetector.deriveStartError(openResult: kIOReturnSuccess, deviceCount: 0)
        guard case .hardwareUnavailable(let trigger, _) = result else {
            XCTFail("expected .hardwareUnavailable, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(trigger, .deskBang)
    }

    func testDeriveStartErrorReturnsNeedsPrivilegedAccessOnNotPrivileged() {
        // Running without sudo: IOHIDManagerOpen returns kIOReturnNotPrivileged.
        let result = AccelerometerDetector.deriveStartError(openResult: kIOReturnNotPrivileged, deviceCount: 0)
        guard case .needsPrivilegedAccess(let trigger, _) = result else {
            XCTFail("expected .needsPrivilegedAccess, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(trigger, .deskBang)
    }

    func testDeriveStartErrorReturnsInputSetupFailedOnOtherIOReturn() {
        // Any other IOReturn code: a generic input-setup-failed wrapping
        // the hex code so the user has something to grep. IOReturn is
        // Int32; bitPattern: lets us specify negative-bit values via
        // their unsigned hex representation.
        let bogusResult = IOReturn(bitPattern: 0xE00002C5)  // arbitrary non-zero, non-privileged
        let result = AccelerometerDetector.deriveStartError(openResult: bogusResult, deviceCount: 0)
        guard case .inputSetupFailed(let trigger, let underlying) = result else {
            XCTFail("expected .inputSetupFailed, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(trigger, .deskBang)
        XCTAssertTrue(underlying.contains("e00002c5"), "underlying message should include the hex IOReturn for grep-ability; got: \(underlying)")
    }
}
