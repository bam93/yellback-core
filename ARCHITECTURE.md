# YellBack Core — Architecture

This document is the architectural reference for `yellback-core`. It covers *why* the code is shaped the way it is. The CLAUDE.md file covers *what* to do; this one covers why.

## The Signal/Event Duality

This is the most important concept in the codebase. Every detector emits two kinds of output:

**Discrete `TriggerEvent`s** — fire when the detector crosses its threshold. Have a type (scream / rage_type / desk_bang), a timestamp, and an intensity (0.0–1.0). The audio engine subscribes to these and plays sound clips in response. Cooldowns apply between events of the same type.

**Continuous `IntensitySignal`s** — emitted at each detector's sample rate regardless of whether a threshold was crossed. A 0.0–1.0 value representing the "how much is happening right now" signal for that detector. In v1, nothing consumes these. In v2, a planned multimodal fusion module will consume them to compute a unified frustration score.

Both outputs are live in v1. The `onIntensity` callback on `YellBackEngine` is a public API contract even though v1's consumers (the CLI and the Mac app) don't use it. This is deliberate forward-compat — removing it to "simplify" would force a painful v2 refactor.

## Why Three Independent Detectors

The mic, keyboard, and accelerometer detectors run as independent components, each with its own threshold, cooldown, and intensity calculation. They do not share state directly. Cross-trigger behaviour (the priming state) is mediated by the engine, not by direct detector-to-detector communication.

This matters because:
1. Detectors can be individually tested with synthetic input
2. Users can disable triggers independently via config
3. Porting to v2 (Rust/Tauri) can happen one detector at a time
4. A detector that crashes or stalls doesn't take down the others

## The Priming State

When any trigger fires, the engine enters "primed" state for a configurable window (default 5 seconds). While primed, the *other* triggers' thresholds are multiplied by a configurable factor (default 0.75), making them easier to fire. The trigger that caused the priming is NOT itself easier to fire — this prevents auto-retrigger loops.

The effect: once the user is in the zone (yelling, raging), the other sensors get more sensitive to whatever they're picking up. A small desk tap that wouldn't normally fire anything will fire during an active scream session. Once the user calms down (5 seconds of no triggers), thresholds reset.

The priming state is the one piece of "intelligence" in v1. It's a hand-tuned state machine, not ML. It makes the three detectors feel like a coherent system instead of three independent sensors reporting independently.

**Implementation:** `PrimingState` is owned by `YellBackEngine`. Detectors consult it before firing — they ask "given my current reading and the priming state, should I fire?" rather than applying thresholds independently.

## Why No UI Frameworks

`yellback-core` does not import AppKit, SwiftUI, or UIKit. This is a hard rule, enforced in CI.

The reason is forward-compat. v2's planned Windows/Linux implementation is a rewrite in Rust + Tauri, not a port of Swift code. But the *architecture* — detectors, signals, events, priming state, pack format, config schema — must survive that rewrite unchanged. If the core couples itself to Swift UI frameworks, the v2 architecture would have to be re-derived from scratch; keeping it UI-free means v2 is a translation exercise, not a re-design exercise.

Foundation, AVFoundation, CoreMotion, and CoreGraphics (for CGEventTap) are acceptable dependencies — they're OS-level APIs that Rust equivalents exist for on Windows/Linux. Yams (YAML parsing) is acceptable because Rust has serde_yaml.

## Public API Surface

The complete public API of `yellback-core` is:

```swift
public final class YellBackEngine {
    public init(config: EngineConfig)
    public func start() throws
    public func stop()
    public func setPack(id: String) throws
    public func loadPack(from url: URL) throws

    public var onTrigger: ((TriggerEvent) -> Void)?
    public var onIntensity: ((Trigger, IntensitySignal) -> Void)?
    public var onPermissionStateChange: ((PermissionState) -> Void)?
}

public enum Trigger {
    case scream, rageType, deskBang
}

public struct TriggerEvent {
    public let trigger: Trigger
    public let timestamp: Date
    public let intensity: Double  // 0.0 - 1.0
    public let wasPrimed: Bool    // Did priming state affect this firing?
}

public struct IntensitySignal {
    public let value: Double      // 0.0 - 1.0
    public let timestamp: Date
}

public struct PermissionState {
    public let microphone: PermissionStatus
    public let accessibility: PermissionStatus
}
```

Additions to the public API require a minor version bump. Breaking changes require a major version bump. The paid app pins an exact version of the core; additions are safe, removals are not.

## Config-First Design

Every tunable parameter has a config entry. Nothing is hardcoded to a magic number in the detectors. This matters because:
- Users can tune the app without recompiling
- Tests can load synthetic configs to exercise edge cases
- The paid app can ship preset configs ("office mode," "studio mode") without a forked codebase

The canonical config schema lives in `CONFIG_SCHEMA.md` and `config.example.yaml`. These two must stay in sync — if you change the schema, update both.

## Audio Engine Notes

`SoundEngine` wraps `AVAudioEngine`. Key decisions:

- **Clips are preloaded as `AVAudioPCMBuffer`** at pack-switch time, never at trigger time. Disk I/O during a trigger would blow the 100ms latency budget.
- **A pool of 8 `AVAudioPlayerNode`s** handles concurrent playback. When a trigger fires, grab an idle node, play the buffer, return to pool on completion. This handles the case where two triggers fire within 50ms of each other.
- **Master volume follows system volume** unless the consumer overrides. Respect mute. (An app that yells at you when your system is muted is a bug.)
- **Clips are `.caf`** (Core Audio Format). Lower decode latency than mp3 or wav.
- **No-repeat rule:** track recently-played clips per session, avoid repeats until the tier's pool is exhausted. Without this, users would hear the same scream twice in ten seconds and the illusion breaks.

## Testing Strategy

Each detector has a unit test file that:
1. Loads a synthetic input fixture (recorded audio sample, keystroke trace, motion trace)
2. Instantiates the detector with a test config
3. Asserts that triggers fire (or don't fire) at expected timestamps
4. Asserts intensity values fall in expected ranges

Synthetic fixtures live in `Tests/YellBackCoreTests/Fixtures/`. When tuning a detector changes its behaviour, the test fixture's expectations must be updated in the same commit. Never loosen a test to make it pass without understanding why it broke.

Integration tests are deferred: they'd require a real mic, accelerometer, and keyboard, which is hard in CI. The CLI's smoke-test mode (`yellback --self-test`) covers that territory manually.

## What's NOT in This Architecture

To be explicit about things that might seem like good ideas but aren't:

- **No ML.** No on-device sentiment model. No speaker identification. The brand promise is "you scream, it yells back" — injecting intelligence that might suppress a trigger breaks the causal loop users expect.
- **No cloud.** Zero network calls from this package. (Pack downloads happen in the paid app, not in the core.)
- **No user data collection.** Ever. The core has no analytics SDK, no crash reporter, no telemetry. If a user wants to report a bug, they copy-paste from `--log-level debug`.
- **No account system.** The core has no concept of a user.
