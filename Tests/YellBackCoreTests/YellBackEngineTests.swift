import XCTest
@testable import YellBackCore

/// Tests for the public `YellBackEngine` engine class.
///
/// The engine sits between detectors and the audio output. We can't bring
/// up real `MicDetector` (mic permission) or `AccelerometerDetector` (sudo
/// + SPU sensor) in CI, so these tests use a `FakeDetector` helper that
/// conforms to the `Detector` protocol and exposes a synchronous `inject`
/// path. The engine's internal `init(config:detectors:playbackRecorder:)`
/// accepts pre-built detectors and a closure that records playback calls
/// without a real `SoundEngine`.
final class YellBackEngineTests: XCTestCase {

    // MARK: - Anchor + helpers

    private let anchor = Date(timeIntervalSince1970: 1_000_000)

    private func makeConfig() -> EngineConfig {
        return EngineConfig()
    }

    private func event(_ trigger: Trigger,
                       at offset: TimeInterval,
                       intensity: Double = 0.5,
                       wasPrimed: Bool = false) -> TriggerEvent {
        return TriggerEvent(
            trigger: trigger,
            timestamp: anchor.addingTimeInterval(offset),
            intensity: intensity,
            wasPrimed: wasPrimed
        )
    }

    // MARK: - Stats counters

    func testStatsCountersIncrementPerTriggerType() {
        let scream = FakeDetector(trigger: .scream)
        let deskBang = FakeDetector(trigger: .deskBang)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream, deskBang],
            playbackRecorder: { _ in }
        )

        scream.inject(event: event(.scream, at: 0))
        scream.inject(event: event(.scream, at: 10))
        deskBang.inject(event: event(.deskBang, at: 20))

        let stats = engine.stats
        XCTAssertEqual(stats.screamCount, 2)
        XCTAssertEqual(stats.deskBangCount, 1)
        XCTAssertEqual(stats.rageTypeCount, 0)
    }

    // MARK: - Cooldown gate

    func testCooldownSuppressesSecondScreamWithinWindow() {
        var played: [Double] = []
        let scream = FakeDetector(trigger: .scream)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream],
            playbackRecorder: { played.append($0) }
        )
        var observedTriggers = 0
        engine.onTrigger = { _ in observedTriggers += 1 }

        // Two screams 0.5s apart; default scream cooldownSeconds is 1.0.
        scream.inject(event: event(.scream, at: 0,   intensity: 0.5))
        scream.inject(event: event(.scream, at: 0.5, intensity: 0.6))

        XCTAssertEqual(observedTriggers, 2,
                       "both events fire onTrigger; cooldown only gates audio")
        XCTAssertEqual(played.count, 1, "only the first scream plays audio")
        XCTAssertEqual(played.first ?? -1, 0.5, accuracy: 0.0001)

        let stats = engine.stats
        XCTAssertEqual(stats.screamCount, 2)
        XCTAssertEqual(stats.suppressedByCooldownCount, 1)
        XCTAssertEqual(stats.playbackCount, 1)
    }

    func testCooldownAllowsScreamPastWindow() {
        var played: [Double] = []
        let scream = FakeDetector(trigger: .scream)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream],
            playbackRecorder: { played.append($0) }
        )

        // Two screams 2s apart; default scream cooldownSeconds is 1.0.
        scream.inject(event: event(.scream, at: 0,   intensity: 0.5))
        scream.inject(event: event(.scream, at: 2.0, intensity: 0.6))

        XCTAssertEqual(played.count, 2)
        XCTAssertEqual(engine.stats.suppressedByCooldownCount, 0)
        XCTAssertEqual(engine.stats.playbackCount, 2)
    }

    /// Boundary: at EXACTLY `cooldownSeconds` (the strict-less-than edge),
    /// the second event MUST play. Per "Session 2.5 standard" — accept-at-
    /// boundary AND reject-just-outside coverage on every closed-interval rule.
    func testCooldownAtBoundaryAllowsSecondScream() {
        var played: [Double] = []
        let scream = FakeDetector(trigger: .scream)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream],
            playbackRecorder: { played.append($0) }
        )

        let cooldown = ScreamConfig.default.cooldownSeconds
        scream.inject(event: event(.scream, at: 0,        intensity: 0.5))
        scream.inject(event: event(.scream, at: cooldown, intensity: 0.6))

        XCTAssertEqual(played.count, 2,
                       "at exactly cooldownSeconds the comparison < cooldown is false → plays")
        XCTAssertEqual(engine.stats.suppressedByCooldownCount, 0)
    }

    /// Boundary: just-inside-cooldown (one nanosecond shy) MUST suppress.
    /// Pairs with the at-boundary test to lock the strict comparison.
    func testCooldownJustInsideWindowSuppresses() {
        var played: [Double] = []
        let scream = FakeDetector(trigger: .scream)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream],
            playbackRecorder: { played.append($0) }
        )

        let cooldown = ScreamConfig.default.cooldownSeconds
        scream.inject(event: event(.scream, at: 0,                   intensity: 0.5))
        scream.inject(event: event(.scream, at: cooldown - 0.001,    intensity: 0.6))

        XCTAssertEqual(played.count, 1)
        XCTAssertEqual(engine.stats.suppressedByCooldownCount, 1)
    }

    func testCooldownIsPerTriggerScreamDoesNotGateDeskBang() {
        var played: [Double] = []
        let scream = FakeDetector(trigger: .scream)
        let deskBang = FakeDetector(trigger: .deskBang)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream, deskBang],
            playbackRecorder: { played.append($0) }
        )

        // Within scream's cooldown but for a DIFFERENT trigger — both play.
        scream.inject(event: event(.scream, at: 0,   intensity: 0.5))
        deskBang.inject(event: event(.deskBang, at: 0.1, intensity: 0.6))

        XCTAssertEqual(played.count, 2,
                       "different triggers are not gated against each other")
        XCTAssertEqual(engine.stats.suppressedByCooldownCount, 0)
    }

    // MARK: - Priming

    func testPrimingAppliesMultiplierToOtherDetector() throws {
        // Use a long window (60s — the validation upper bound) and a fixed
        // multiplier so the test is robust under heavy CI load. The engine's
        // applyMultipliers compares wall-clock `Date()` against
        // `event.timestamp + windowSeconds`; with `event.timestamp = Date()`
        // and a 60-second window, the multiplier check has a generous margin.
        let longWindow = try PrimingConfig(enabled: true,
                                           windowSeconds: 60.0,
                                           thresholdMultiplier: 0.5)
        let config = EngineConfig(
            triggers: TriggersConfig.default,
            priming: longWindow,
            audio: AudioConfig.default,
            packsDirectory: EngineConfig.defaultPacksDirectory,
            logging: LoggingConfig.default
        )
        let scream = FakeDetector(trigger: .scream)
        let deskBang = FakeDetector(trigger: .deskBang)
        let engine = YellBackEngine(
            config: config,
            detectors: [scream, deskBang],
            playbackRecorder: { _ in }
        )

        // Pre-condition: both at 1.0.
        XCTAssertEqual(scream.primingMultiplier, 1.0)
        XCTAssertEqual(deskBang.primingMultiplier, 1.0)

        scream.inject(event: TriggerEvent(
            trigger: .scream, timestamp: Date(), intensity: 0.5, wasPrimed: false
        ))

        // Originating trigger keeps 1.0; others get the primed multiplier.
        XCTAssertEqual(scream.primingMultiplier, 1.0,
                       "originating trigger keeps 1.0 (auto-retrigger guard)")
        XCTAssertEqual(deskBang.primingMultiplier, 0.5, accuracy: 0.0001,
                       "non-originating detector gets the configured multiplier")

        engine.stop()
    }

    func testPrimingDisabledLeavesAllMultipliersAtOne() throws {
        let disabledPriming = try PrimingConfig(enabled: false,
                                                windowSeconds: 5.0,
                                                thresholdMultiplier: 0.75)
        let config = EngineConfig(
            triggers: TriggersConfig.default,
            priming: disabledPriming,
            audio: AudioConfig.default,
            packsDirectory: EngineConfig.defaultPacksDirectory,
            logging: LoggingConfig.default
        )
        let scream = FakeDetector(trigger: .scream)
        let deskBang = FakeDetector(trigger: .deskBang)
        _ = YellBackEngine(
            config: config,
            detectors: [scream, deskBang],
            playbackRecorder: { _ in }
        )

        scream.inject(event: TriggerEvent(
            trigger: .scream, timestamp: Date(), intensity: 0.5, wasPrimed: false
        ))

        XCTAssertEqual(scream.primingMultiplier, 1.0)
        XCTAssertEqual(deskBang.primingMultiplier, 1.0,
                       "disabled priming must not lower the multiplier")
    }

    // MARK: - onTrigger forwarding

    func testOnTriggerFiresUnconditionallyIncludingForCooldownSuppressed() {
        var observed: [TriggerEvent] = []
        let scream = FakeDetector(trigger: .scream)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream],
            playbackRecorder: { _ in }
        )
        engine.onTrigger = { observed.append($0) }

        scream.inject(event: event(.scream, at: 0))
        scream.inject(event: event(.scream, at: 0.1))   // suppressed by cooldown

        XCTAssertEqual(observed.count, 2,
                       "consumers see all events; only audio is gated by cooldown")
    }

    // MARK: - onIntensity forwarding

    func testOnIntensityForwardsWithCorrectTriggerDiscriminator() {
        var observed: [(Trigger, Double)] = []
        let scream = FakeDetector(trigger: .scream)
        let deskBang = FakeDetector(trigger: .deskBang)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream, deskBang],
            playbackRecorder: { _ in }
        )
        engine.onIntensity = { trigger, signal in
            observed.append((trigger, signal.value))
        }

        scream.inject(signal: IntensitySignal(value: 0.42, timestamp: anchor))
        deskBang.inject(signal: IntensitySignal(value: 0.71, timestamp: anchor))

        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(observed[0].0, .scream)
        XCTAssertEqual(observed[0].1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(observed[1].0, .deskBang)
        XCTAssertEqual(observed[1].1, 0.71, accuracy: 0.0001)
    }

    // MARK: - Pack handling

    func testSetPackOfUnknownIdThrowsPackNotFound() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yellback-engine-test-\(UUID().uuidString)")
        let config = EngineConfig(
            triggers: TriggersConfig.default,
            priming: PrimingConfig.default,
            audio: AudioConfig.default,
            packsDirectory: tempDir,
            logging: LoggingConfig.default
        )
        let engine = YellBackEngine(config: config)

        XCTAssertThrowsError(try engine.setPack(id: "nonexistent")) { error in
            guard case EngineError.packNotFound(let id, _) = error else {
                XCTFail("expected EngineError.packNotFound, got \(error)")
                return
            }
            XCTAssertEqual(id, "nonexistent")
        }
    }

    // MARK: - Lifecycle idempotency

    func testStopIsIdempotent() {
        let scream = FakeDetector(trigger: .scream)
        let engine = YellBackEngine(
            config: makeConfig(),
            detectors: [scream],
            playbackRecorder: { _ in }
        )
        engine.stop()
        engine.stop()  // second call must not crash
    }
}

// MARK: - FakeDetector test helper

/// A test-only `Detector` conformer. Tests inject events / signals via
/// `inject(event:)` / `inject(signal:)`; the engine's wired callbacks
/// route through normally.
final class FakeDetector: Detector {
    let trigger: Trigger
    var isEnabled: Bool = true
    var primingMultiplier: Double = 1.0
    var onTriggerEvent: ((TriggerEvent) -> Void)?
    var onIntensitySignal: ((IntensitySignal) -> Void)?

    init(trigger: Trigger) {
        self.trigger = trigger
    }

    func start() throws {}
    func stop() {}

    /// Drive an event through the wired engine callback. Synchronous —
    /// the engine runs handleTriggerEvent on the calling thread (it
    /// internally uses queue.sync).
    func inject(event: TriggerEvent) {
        onTriggerEvent?(event)
    }

    /// Drive an intensity signal through the wired engine callback.
    func inject(signal: IntensitySignal) {
        onIntensitySignal?(signal)
    }
}
