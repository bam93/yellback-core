import XCTest
@testable import YellBackCore

/// Tests for the engine-owned `PrimingState` value-type state machine.
///
/// `PrimingState` is the engine's mechanism for cross-trigger sensitization
/// (per `ARCHITECTURE.md` §"The Priming State"). When any trigger fires,
/// the *other* triggers' thresholds are temporarily lowered for
/// `priming.window_seconds`. The trigger that caused priming keeps its
/// own threshold to prevent auto-retrigger loops.
///
/// These tests are pure — no detectors, no engine, no audio. The state
/// machine is a `Date`-driven value type; tests advance "time" by passing
/// concrete `Date` values to the transition functions.
final class PrimingStateTests: XCTestCase {

    // MARK: - Helpers

    private let defaultConfig = PrimingConfig.default

    /// A deterministic anchor `Date` used as "now = 0" for tests.
    private let anchor = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Idle state

    func testIdleReturnsUnitMultiplierForAllTriggers() {
        let state = PrimingState()
        XCTAssertEqual(state.multiplier(for: .scream, at: anchor, config: defaultConfig), 1.0)
        XCTAssertEqual(state.multiplier(for: .deskBang, at: anchor, config: defaultConfig), 1.0)
        XCTAssertEqual(state.multiplier(for: .rageType, at: anchor, config: defaultConfig), 1.0)
        XCTAssertEqual(state.phase, .idle)
    }

    func testTickInIdleIsNoOp() {
        var state = PrimingState()
        state.tick(at: anchor)
        XCTAssertEqual(state.phase, .idle)
        state.tick(at: anchor.addingTimeInterval(1_000))
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Entering primed state

    func testTriggerEntersPrimedStateForOriginatingTrigger() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)

        if case .primed(let originating, let expiresAt) = state.phase {
            XCTAssertEqual(originating, .scream)
            XCTAssertEqual(expiresAt, anchor.addingTimeInterval(defaultConfig.windowSeconds))
        } else {
            XCTFail("expected primed state, got \(state.phase)")
        }
    }

    func testOriginatingTriggerKeepsUnitMultiplierWhilePrimed() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)

        // Originating trigger stays at 1.0 (auto-retrigger guard).
        XCTAssertEqual(state.multiplier(for: .scream, at: anchor, config: defaultConfig), 1.0)
    }

    func testOtherTriggersGetPrimedMultiplierWhilePrimed() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)

        XCTAssertEqual(state.multiplier(for: .deskBang, at: anchor, config: defaultConfig),
                       defaultConfig.thresholdMultiplier)
        XCTAssertEqual(state.multiplier(for: .rageType, at: anchor, config: defaultConfig),
                       defaultConfig.thresholdMultiplier)
    }

    // MARK: - Window expiry boundaries

    func testJustBeforeExpiryStillPrimed() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let justBeforeExpiry = anchor.addingTimeInterval(defaultConfig.windowSeconds - 0.001)

        XCTAssertEqual(state.multiplier(for: .deskBang, at: justBeforeExpiry, config: defaultConfig),
                       defaultConfig.thresholdMultiplier,
                       "0.001s before expiry, deskBang should still see the primed multiplier")
    }

    func testAtExpiryReturnsToIdle() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let atExpiry = anchor.addingTimeInterval(defaultConfig.windowSeconds)

        // multiplier(at:) treats expiresAt as the boundary: at and beyond → 1.0.
        XCTAssertEqual(state.multiplier(for: .deskBang, at: atExpiry, config: defaultConfig), 1.0,
                       "at expiry instant, deskBang should no longer see primed multiplier")
    }

    func testJustAfterExpiryReturnsToIdle() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let justAfter = anchor.addingTimeInterval(defaultConfig.windowSeconds + 0.001)

        XCTAssertEqual(state.multiplier(for: .deskBang, at: justAfter, config: defaultConfig), 1.0)
    }

    func testTickPastExpiryTransitionsToIdle() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let past = anchor.addingTimeInterval(defaultConfig.windowSeconds + 0.5)
        state.tick(at: past)
        XCTAssertEqual(state.phase, .idle)
    }

    func testTickBeforeExpiryStaysPrimed() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let before = anchor.addingTimeInterval(defaultConfig.windowSeconds - 1.0)
        state.tick(at: before)
        if case .primed = state.phase {
            // pass
        } else {
            XCTFail("tick before expiry must NOT transition to idle; got \(state.phase)")
        }
    }

    // MARK: - Re-trigger semantics

    func testNewTriggerDuringPrimedResetsWindow() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let mid = anchor.addingTimeInterval(2.0)
        state.onTrigger(.deskBang, at: mid, config: defaultConfig)

        if case .primed(_, let expiresAt) = state.phase {
            // Window resets to mid + windowSeconds, NOT extended additively.
            XCTAssertEqual(expiresAt, mid.addingTimeInterval(defaultConfig.windowSeconds))
        } else {
            XCTFail("expected still primed after second trigger, got \(state.phase)")
        }
    }

    func testNewTriggerDuringPrimedChangesOriginatingTrigger() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let mid = anchor.addingTimeInterval(2.0)
        state.onTrigger(.deskBang, at: mid, config: defaultConfig)

        // The trigger that just fired becomes the originating trigger;
        // it gets the auto-retrigger guard (multiplier 1.0). The previously-
        // originating trigger now gets the primed multiplier.
        XCTAssertEqual(state.multiplier(for: .deskBang, at: mid, config: defaultConfig), 1.0,
                       "new originating trigger keeps 1.0 (auto-retrigger guard)")
        XCTAssertEqual(state.multiplier(for: .scream, at: mid, config: defaultConfig),
                       defaultConfig.thresholdMultiplier,
                       "previously-originating trigger now gets the primed multiplier")
    }

    // MARK: - Config gating

    func testDisabledConfigAlwaysReturnsUnitMultiplier() throws {
        let disabled = try PrimingConfig(enabled: false,
                                         windowSeconds: 5.0,
                                         thresholdMultiplier: 0.75)
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: disabled)

        // Even when phase says primed, disabled config returns 1.0 across the board.
        XCTAssertEqual(state.multiplier(for: .scream, at: anchor, config: disabled), 1.0)
        XCTAssertEqual(state.multiplier(for: .deskBang, at: anchor, config: disabled), 1.0)
        XCTAssertEqual(state.multiplier(for: .rageType, at: anchor, config: disabled), 1.0)
    }

    func testThresholdMultiplierOfOneIsDegenerateNoOp() throws {
        let degenerate = try PrimingConfig(enabled: true,
                                           windowSeconds: 5.0,
                                           thresholdMultiplier: 1.0)
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: degenerate)

        // Even though primed, multiplier == 1.0 means no-op effective threshold.
        XCTAssertEqual(state.multiplier(for: .deskBang, at: anchor, config: degenerate), 1.0)
        XCTAssertEqual(state.multiplier(for: .rageType, at: anchor, config: degenerate), 1.0)
    }

    // MARK: - Lookup is non-mutating

    func testMultiplierLookupDoesNotMutateState() {
        var state = PrimingState()
        state.onTrigger(.scream, at: anchor, config: defaultConfig)
        let snapshot = state
        _ = state.multiplier(for: .deskBang, at: anchor, config: defaultConfig)
        XCTAssertEqual(state, snapshot, "multiplier(for:) must not mutate state")
    }
}
