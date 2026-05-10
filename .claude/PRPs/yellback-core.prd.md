# PRD: yellback-core remaining roadmap

**Owner:** Marc Baaden
**Repo:** github.com/bam93/yellback-core
**Audience:** Everything Claude Code, driven by `/prp-implement` per session
**Last updated:** 2026-05-09
**Last completed session in repo:** Session 4 (audio output stack)

This is the canonical roadmap for finishing the yellback-core open-source detection engine. Each phase below corresponds to one Claude Code session. Phases are picked by `/prp-implement` in dependency order; status is updated when a phase completes.

**Two reaction outlets** are part of the v1 surface: audio (from `SoundEngine` + sound packs, shipped Session 4) and text (from `TextEngine` + text packs, landing Phase 5c). A **dialogue mode** in Phase 5d makes them call-and-response — the user yells, the computer yells back, the user yells back, the computer yells back, until silence terminates the exchange. Mic suppression during the engine's own playback prevents acoustic feedback from re-triggering the dialogue artificially.

The repo's existing conventions — Sessions 1–4 testing bar, no feature branches, fast-forward main, HEREDOC commits with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`, the IOKit/AVAudioEngine footgun list in SESSION_HANDOFF.md §7 — apply to every phase. They are also pinned in `CLAUDE.md` under "ECC Handoff Conventions" and override any conflicting ECC defaults.

## Implementation Phases

---

### Phase 5 — YellBackEngine public API + PrimingState + cooldown filtering + SessionStats

**Status:** `complete` (Session 5, 2026-05-10) — 162/162 tests green; engine wiring verified live on M2 via the intensity-signal stream (both detectors deliver continuous data through the engine). Trigger-crossing demo (`[trigger]` line + audio) NOT verified live: at-rest readings (~1.0–1.05g; ambient mic 0.000) didn't cross the documented-too-high thresholds (1.5g / -20 dBFS). Trigger-crossing verification deferred to Phase 5b's calibration session, when thresholds get lowered to a level natural input can actually hit.
**Depends on:** —
**Estimated scope:** large; ~1 full session.

**Description.** Replace the CLI's direct detector → SoundEngine wiring with the public `YellBackEngine` from `ARCHITECTURE.md` §"Public API Surface". The engine owns:

- the three detectors and their lifecycle (`start()` / `stop()`)
- the `SoundEngine` and pack loading
- `PrimingState` cross-trigger coordination (the `Detector.primingMultiplier` hooks already exist on `MicDetector` and `AccelerometerDetector` — Session 3 addendum landed them; Session 5 wires them)
- engine-level cooldown filtering using each detector's `cooldownSeconds` from config (currently captured but unused — detectors emit at natural cadence; engine filters)
- `SessionStats` counters (currently a stub at `Sources/YellBackCore/Stats/SessionStats.swift`)
- the `PermissionState` surface (`PermissionState`, `PermissionStatus` already exist; engine surfaces transitions via `onPermissionStateChange`)

**Required public API surface** (per `ARCHITECTURE.md` lines 47–80, MUST match exactly):

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
```

Note `onIntensity`'s shape: `(Trigger, IntensitySignal) -> Void` — the engine adds the `Trigger` discriminator that detectors don't carry on their per-detector callbacks. v1 consumers ignore this; the v2 fusion module consumes it. Do NOT remove or simplify.

**PrimingState semantics** (per `ARCHITECTURE.md` §"The Priming State", `CONFIG_SCHEMA.md` §`priming`):

- When any trigger fires, engine enters primed state for `priming.window_seconds` (default 5s).
- During priming, the **other** triggers' `primingMultiplier` is set to `priming.threshold_multiplier` (default 0.75); the trigger that *caused* priming keeps `1.0` to prevent auto-retrigger loops.
- If another trigger fires during priming, the window resets to full length (does NOT extend additively).
- After the window expires with no further triggers, all multipliers return to `1.0`.

**Cooldown filtering semantics:**

- Detectors emit at natural cadence (`MicDetector` at sustain cadence ~3.3 Hz for default 0.3s sustain; `AccelerometerDetector` per impulse; `KeyboardDetector` once it lands).
- Engine receives every event, increments `SessionStats`, then suppresses audio playback if the previous event of the *same trigger* was within `cooldownSeconds`.
- Suppressed-by-cooldown events still fire `onTrigger` callbacks (consumers see all events; SessionStats sees all events; only `SoundEngine.play(...)` is gated). This keeps `SessionStats` honest and lets the paid Mac app show "you were yelled-back-at suppressed by cooldown" in its activity log.

**Files to create / change:**

- `Sources/YellBackCore/YellBackEngine.swift` — currently a stub; rewrite with full implementation.
- `Sources/YellBackCore/Signals/PrimingState.swift` — currently a stub; implement.
- `Sources/YellBackCore/Stats/SessionStats.swift` — currently a stub; implement counters per trigger (`screamCount`, `rageTypeCount`, `deskBangCount`, `playbackCount`, `suppressedByCooldownCount`, `suppressedByMutedSystemCount`).
- `Sources/yellback-cli/main.swift` — replace ~80 lines of direct detector wiring with ~10 lines that build a `YellBackEngine` and observe its callbacks.
- `Tests/YellBackCoreTests/YellBackEngineTests.swift` — new file. Engine wiring under synthetic inputs; PrimingState transitions; cooldown filtering; SessionStats counters.
- `Tests/YellBackCoreTests/PrimingStateTests.swift` — new file. Pure state-machine tests on `PrimingState` (boundary tests on the window, the "originating trigger keeps 1.0" rule, the reset-on-fresh-trigger rule).

**Reuse, do not reinvent:**

- `Detector` protocol at `Sources/YellBackCore/Detectors/Detector.swift` — engine consumes via this protocol; do NOT couple engine to concrete detector classes.
- `Detector.primingMultiplier` already public on `MicDetector` and `AccelerometerDetector` — engine sets it during PrimingState transitions.
- `SoundEngine.play(intensity:)` — unchanged contract; engine calls it after cooldown gate passes.
- `EngineConfig` — already includes all needed fields; no schema change needed.

**Acceptance criteria:**

- All public API surface matches `ARCHITECTURE.md` lines 47–80 exactly.
- 145+ tests passing (135 baseline + 10+ new).
- `swift build` and `DEVELOPER_DIR=… swift test` both green.
- The CLI's `--listen` mode behaves identically from the user's perspective: `[trigger]` lines on stderr, audio plays from the matching tier, Ctrl-C stops cleanly.
- New: when two screams happen within `scream.cooldown_seconds`, both fire `onTrigger`, only the first plays audio, `SessionStats.suppressedByCooldownCount == 1`.
- New: when a scream fires, the next desk_bang within `priming.window_seconds` fires at the lowered effective threshold and carries `wasPrimed: true`.
- PROGRESS.md and SESSION_HANDOFF.md updated.

**Hardware-in-loop steps:**

- End-of-session: run `sudo swift run yellback --config config.example.yaml --listen`. Confirm `[trigger]` lines for both scream and desk_bang, audio plays, Ctrl-C stops cleanly, no crashes on stop.
- Confirm both detectors still gracefully degrade when the other can't start (existing behavior must not regress).

**Out of scope:**

- Calibration (Phase 7).
- Device-change handling (Phase 4b).
- KeyboardDetector (Phase 6).

---

### Phase 5b — Interim desk_bang threshold tweak

**Status:** `pending`
**Depends on:** Phase 5 (recommended order; not strictly blocking — could land before, but the engine wiring should land first to avoid two churns of the CLI surface)

**Description.** The empirical M2 finding (PROGRESS.md "Known Issues" #5, captured 2026-04-26) is that `desk_bang.g_force_threshold: 1.5` is too high — natural taps don't fire, only firm slams do. This phase is the one-line stopgap until Phase 7 (calibration onboarding) ships: measure on M2, pick a better default, update `config.example.yaml` and `Sources/YellBackCore/Config/EngineConfig.swift`'s `DeskBangConfig.init` default.

**Files to change:**

- `config.example.yaml` line 19 (`g_force_threshold: 1.5` → measured value).
- `Sources/YellBackCore/Config/EngineConfig.swift` line 140 (`gForceThreshold: Double = 1.5` → measured value).
- `Tests/YellBackCoreTests/AccelerometerDetectorTests.swift` — update fixtures that assume 1.5g; the boundary tests use specific magnitudes (e.g., `2.5` produces delta `1.5` exactly at threshold). Adjust to the new threshold so `testGForceDeltaAtThresholdTriggers`, `testGForceDeltaJustBelowThresholdDoesNotTrigger`, `testGForceDeltaJustAboveThresholdTriggers` continue to test "exactly at the new threshold" rather than "exactly at 1.5g".
- `Tests/YellBackCoreTests/ConfigLoaderTests.swift` line 27 (`XCTAssertEqual(c.triggers.deskBang.gForceThreshold, 1.5)` → new value).
- PROGRESS.md "Known Issues" #5 — note the empirical update; flag that Phase 7 calibration is still planned.

**Acceptance criteria:**

- `swift build` + `swift test` green with all updated fixtures.
- New default fires on a "firm but comfortable" tap on M2 (verified by user). Natural typing / laptop pickup does NOT fire.

**Hardware-in-loop steps (mandatory — phase cannot land without):**

- User runs an instrumented `--listen` session on M2 with `logging.level: debug` so per-impulse g-force values print.
- User performs (in order, recording the printed g-force delta for each): typing a paragraph; picking up the laptop and setting it down; light tap; comfortable tap; firm tap; deliberate slam.
- User reports the values back to ECC. ECC picks a default just above the "comfortable tap" cluster.

**Empirical baseline from Session 5 debug-listen (2026-05-10):**

- At-rest accelerometer: `intensity` 0.000–0.003 (g_force ≈ 1.00–1.01g — gravity baseline + ambient noise from the laptop sitting on a surface).
- Light handling / approach to keyboard: `intensity` 0.003–0.008 (g_force ≈ 1.01–1.02g).
- A measured "comfortable tap" near the end of the log: peak `intensity` 0.016 (g_force ≈ 1.05g) with the characteristic decay shape of a real impulse.
- The current `gForceThreshold: 1.5` requires `intensity ≥ 0.167` — about 10× the comfortable-tap peak. Calibration target should land somewhere around `intensity ≈ 0.020–0.040` (g_force ≈ 1.06–1.12g).

**Out of scope:**

- Per-machine calibration (Phase 7).
- Touching the `intensity = delta / 3` mapping (also uncalibrated; Phase 7).

---

### Phase 5c — TextEngine + TextPack + bundled placeholder text pack + `onTextReaction`

**Status:** `pending`
**Depends on:** Phase 5 (engine wiring exists)

**Description.** Add the second reaction outlet alongside audio. When a non-cooldown-suppressed `TriggerEvent` fires, the engine picks a phrase from the active text pack's matching tier (low / medium / high) and emits it via:

- `stderr` from the CLI, formatted as `[yell-back] <phrase>` (e.g. `[yell-back] shut UP already`).
- `YellBackEngine.onTextReaction` callback so the paid Mac app can render rich UI (toast, banner, animation).

Mirrors the audio path's architecture exactly — same tier mapping, same per-tier no-repeat tracking, same pack-folder layout, same per-pack licensing rule in `ATTRIBUTIONS.md`. "Same architecture twice" is intentional; reduces what a contributor must learn.

**Required public API additions** (additive to Phase 5 — does not break v1 consumers; ARCHITECTURE.md updated in this phase):

```swift
public extension YellBackEngine {
    var onTextReaction: ((TextReaction) -> Void)?
}

public struct TextReaction {
    public let trigger: Trigger
    public let timestamp: Date
    public let intensity: Double
    public let phrase: String
    public let wasPrimed: Bool
}
```

**Engine internal:** when a non-suppressed event passes the cooldown gate, the engine calls both `SoundEngine.play(intensity:)` AND `TextEngine.emit(intensity:trigger:wasPrimed:)`. TextEngine fires `onTextReaction` and (when the CLI's stderr-printer subscriber is wired) writes to stderr. Suppressed-by-cooldown events fire neither outlet, but still increment `SessionStats.suppressedByCooldownCount` (same as Phase 5's audio rule).

**Files to create:**

- `Sources/YellBackCore/Text/TextEngine.swift` — orchestrator. Selects phrase, applies no-repeat per tier, emits the reaction.
- `Sources/YellBackCore/Text/TextPack.swift` — value type: `{ id, name, tiers: [Tier: [String]] }`.
- `Sources/YellBackCore/Text/TextPackLoader.swift` — parallel to `PackLoader`. Reads `text.yaml` manifest, validates each tier non-empty, returns a `TextPack`.
- `Sources/YellBackCore/Signals/TextReaction.swift` — public value type above.
- `Resources/Packs/crowd/text.yaml` — bundled placeholder phrase pack. ~10 phrases per tier (low: `["ow.", "yes.", "I HEAR you"]`-ish; medium: stronger; high: full caps energy). All phrases original / unencumbered for v1; Phase 12 replaces with curated content if desired.
- `Tests/YellBackCoreTests/TextEngineTests.swift` — tier selection, no-repeat tracking, emission count per call, RNG-pinned selection (mirror `SoundEngineTests` pattern).
- `Tests/YellBackCoreTests/TextPackLoaderTests.swift` — manifest parsing, missing-tier rejection, empty-tier rejection, bundled-pack drift test parallel to existing `testBundledCrowdPackParsesCleanly`.

**Files to change:**

- `Sources/YellBackCore/YellBackEngine.swift` — add `onTextReaction` callback property; instantiate `TextEngine`; thread it into `setPack` so audio + text pack-switch happens atomically.
- `Sources/yellback-cli/main.swift` — subscribe to `onTextReaction`, print `[yell-back] <phrase>` to stderr alongside existing `[trigger]` lines.
- `ARCHITECTURE.md` — update "Public API Surface" section (lines 47–80) to include `onTextReaction`. Add a "Two reaction outlets" subsection describing audio + text symmetry.
- `Resources/Packs/crowd/pack.yaml` — no change (`text.yaml` is a sibling, not nested).
- `ATTRIBUTIONS.md` — add a "Text content" section parallel to the existing audio section. Note placeholder text is original / unencumbered.

**Reuse, do not reinvent:**

- `Tier` enum currently at `Sources/YellBackCore/Audio/SoundPack.swift` is now shared by audio + text. Move to `Sources/YellBackCore/Signals/Tier.swift` or `Sources/YellBackCore/Packs/Tier.swift` during this phase. Update imports.
- `Yams` parsing — already a dependency; `TextPackLoader` reuses the same patterns as `PackLoader.ParsedManifest.parse(yaml:)`.
- `PackError` cases (`malformedManifest`, `missingField`, `emptyTier`) — consider lifting to a shared `Sources/YellBackCore/Packs/PackError.swift` so both audio and text loaders throw the same type. Decision during implementation; adapter shim in PackLoader is fine if the lift is deferred.
- The bundled `Resources/Packs/crowd/` directory — `text.yaml` is a sibling of the existing `pack.yaml`. One pack ID = one folder = both manifests. No new config field needed; `audio.pack: crowd` resolves both.

**Acceptance criteria:**

- `swift build` + `swift test` green; ~155+ tests (~10 new across TextEngineTests + TextPackLoaderTests).
- CLI's `--listen` mode produces TWO lines per non-suppressed trigger: `[trigger] desk_bang …` AND `[yell-back] <phrase>`.
- `onTextReaction` callback fires with correct tier-matched phrase whenever audio fires.
- Per-tier no-repeat works (cycle through phrases without immediate repeats; reset on tier exhaustion same as `SoundEngine.recentlyPlayed`).
- Bundled crowd `text.yaml` parses cleanly (drift test).
- `ATTRIBUTIONS.md` updated to note text content provenance.

**Hardware-in-loop steps:**

- End-of-session: `sudo swift run yellback --config config.example.yaml --listen`. Tap the Mac. Confirm both audio plays AND `[yell-back] <phrase>` line appears on stderr. Confirm phrase tier matches tap intensity (light tap → low-tier phrase; firm tap → high-tier phrase).

**Out of scope:**

- Real curated text content (Phase 12).
- Dialogue mode (Phase 5d — the call-and-response loop).
- Text-to-speech of the phrases (would replace audio outlet entirely; not v1).
- Per-locale text packs (English-only for v1; localisation later).

---

### Phase 5d — DialogueState + mic suppression + intensity-mirroring rounds

**Status:** `pending`
**Depends on:** Phase 5 (engine state-machine pattern), Phase 5c (recommended order — text + audio dialogue together), Phase 4b (recommended — device-change handler avoids mic-suppression edge cases during dialogue)

**Description.** Make the reactions a back-and-forth dialogue rather than one-shot responses. When a trigger fires, the engine plays its audio + text response, then enters `awaitingUserResponse` for `dialogue.silence_window_seconds` (default `5.0`). If the user fires another trigger within that window, the dialogue continues — computer plays a response matching the user's *current* intensity, then re-enters awaiting state. After the window expires with no triggers, the dialogue terminates and the engine returns to `idle`.

Per the design choice in handoff: **mic is suppressed during the engine's own audio playback** so the engine's own clip can't re-trigger MicDetector. **Each round mirrors the user's current intensity** — back-off begets back-off; escalation begets escalation. **Cooldown gating is bypassed for in-dialogue triggers** — otherwise consecutive responses can't fire fast enough for natural turn-taking.

**State machine** (in `DialogueState.swift`, pure value type with transition functions):

```
idle
  --[trigger fires, dialogue.enabled]--> playingResponse(clipDuration, deadline = now + clipDuration + 0.25s)

playingResponse
  --[playback completes (notified by SoundEngine)]--> awaitingUserResponse(deadline = now + dialogue.silence_window_seconds)
  --[NEW trigger arrives mid-playback]--> latestQueued = trigger (deferred until playback ends)

awaitingUserResponse
  --[trigger fires from user]--> playingResponse with NEW intensity (mirror user)
  --[deadline expires]--> idle (terminate; log "[dialogue] ended after N rounds" at logging.level: debug)
```

**Mic-suppression mechanism:** when entering `playingResponse`, the engine calls `MicDetector.suppressUntil(now + clipDuration + 0.25s)`. Inside `MicDetector.process(buffer:)`, after computing intensity (still emitted via `onIntensitySignal`), the trigger-evaluation step short-circuits if `now < suppressUntilDate`. The intensity signal continues to fire (so the engine can monitor in-dialogue user energy in `[intensity]` debug logs), but no `TriggerEvent` escapes during suppression. This keeps the privacy invariant intact — no extra audio retention; just a date check.

**Termination logging:** when `dialogue.silence_window_seconds` expires with no fresh trigger, engine writes `[dialogue] ended after N rounds` to stderr (only when `logging.level: debug` to avoid clutter).

**Files to create:**

- `Sources/YellBackCore/Signals/DialogueState.swift` — engine-owned state machine. Pure value type with transition functions returning `(newState, sideEffects)`. Side effects are `[suppressMicUntil(Date), playResponse(intensity:Double, originatingTrigger:Trigger)]`.
- `Tests/YellBackCoreTests/DialogueStateTests.swift` — pure state-machine tests. Boundary tests on the silence window. The "mic suppression duration = clip + 250ms" rule. Termination conditions. Mirror-intensity rule (user fires at 0.4 intensity → response at 0.4).

**Files to change:**

- `Sources/YellBackCore/YellBackEngine.swift` — own a `DialogueState`; transition on every `TriggerEvent`. Coordinate `MicDetector.suppressUntil(date)` with `SoundEngine` clip-completion callbacks.
- `Sources/YellBackCore/Detectors/MicDetector.swift` — add `suppressUntil(_ date: Date)` public method. In `process(buffer:)`, check `Date() < suppressUntilDate ? return : evaluateTrigger(...)` after intensity emission. The retained-sample-count privacy invariant remains unchanged (no new buffering).
- `Sources/YellBackCore/Audio/SoundEngine.swift` — replace `node.scheduleBuffer(... completionHandler: nil)` with a closure that fires `onClipComplete?(clipDuration: Double)`. Engine subscribes to drive the dialogue state machine.
- `Sources/YellBackCore/Config/EngineConfig.swift` — add `DialogueConfig` struct: `enabled: Bool = true`, `silenceWindowSeconds: Double = 5.0` (validated `<= 60` via existing `ConfigValidation.checkSecondsUpperBound`). Add `dialogue: DialogueConfig` to `EngineConfig`.
- `Sources/YellBackCore/Config/ConfigLoader.swift` — parse `dialogue:` block; mirror the `priming:` parser pattern.
- `config.example.yaml` — add the `dialogue:` section with annotated defaults.
- `CONFIG_SCHEMA.md` — document `dialogue:` block (`enabled`, `silence_window_seconds`). Same `_seconds <= 60` validation as priming.
- `ARCHITECTURE.md` — add "Dialogue mode" subsection alongside "The Priming State". Note that dialogue is a separate engine-owned state machine that COMPOSES with priming (they run in parallel).
- `Tests/YellBackCoreTests/MicDetectorTests.swift` — add tests for `suppressUntil` behavior: trigger fires before suppression; no trigger fires during suppression; trigger fires after suppression expires; intensity signal fires unchanged through all three.
- `Tests/YellBackCoreTests/YellBackEngineTests.swift` (created in Phase 5) — add dialogue-mode tests: dialogue starts on first trigger, mirrors intensity on round 2, terminates on silence expiry, mic-suppression activated during playback, cooldown bypassed for in-dialogue triggers.
- `Tests/YellBackCoreTests/ConfigBoundaryTests.swift` — boundary tests for `dialogue.silence_window_seconds` (accept 0 and 60, reject -0.01 and 60.01).
- `Tests/YellBackCoreTests/ConfigLoaderTests.swift` — happy-path test that bundled `config.example.yaml` parses with `dialogue.enabled: true` and `silence_window_seconds: 5.0`.

**Acceptance criteria:**

- `swift build` + `swift test` green; ~165+ tests (~12 new across DialogueStateTests + MicDetectorTests additions + YellBackEngineTests additions + ConfigBoundaryTests additions).
- `dialogue.enabled: false` in config disables the feature entirely; behavior reverts to one-shot reactions identical to Phase 5 baseline.
- With `dialogue.enabled: true` and `silence_window_seconds: 5.0`: scream once → audio + text fires → mic suppressed during playback → user yells again within 5s → computer responds at user's NEW intensity → user goes silent → after 5s, dialogue ends with `[dialogue] ended after N rounds` at debug level.
- Self-feedback test: synthetic loud audio fed into MicDetector during a marked suppression window does NOT fire a trigger event (intensity signal still emits unchanged).
- The dialogue does NOT runaway — terminates cleanly when `silence_window_seconds` elapses with no fresh trigger.
- Cooldown gating is BYPASSED for in-dialogue triggers (otherwise the dialogue can't proceed at human-conversation cadence). Engine-level cooldown still applies to the FIRST trigger that opens a dialogue.
- Privacy invariant unchanged: `MicDetector.retainedAudioSampleCount` stays `<= 8` regardless of dialogue state.

**Hardware-in-loop steps (mandatory):**

- User runs `--listen` on M2; yells; hears audio + sees `[yell-back]` text; yells again before 5s elapses; hears second response at the new intensity; goes silent; after 5s confirms `[dialogue] ended` line on stderr (with `logging.level: debug`).
- User confirms by ear that the computer's own audio playback does NOT trigger the mic detector — silent during the engine's clip → no extra response fires.
- User toggles `dialogue.enabled: false` in config, restarts, confirms one-shot behaviour returns (no dialogue continuation; cooldown gates as before).

**Out of scope:**

- Acoustic echo cancellation (deferred or never).
- Cross-detector dialogue (e.g. user yells, computer yells back, user TAPS, computer responds to tap as "round 2"). v1 dialogue mirrors within the same trigger type for simplicity.
- Per-user dialogue style ("aggressive escalator", "calm mirror", "comedic deflector"). Future packs concern.
- Hard upper bound on dialogue length. If the user keeps yelling, the dialogue keeps going; that's by design.
- TTS-style streaming responses. Dialogue uses pre-recorded clips + pre-written phrases.

---

### Phase 4b — Audio production polish

**Status:** `pending`
**Depends on:** Phase 5 (cleaner to do this once the engine owns the SoundEngine lifecycle)

**Description.** Close the three pieces of `AUDIO_NOTES.md` guidance deferred during Session 4 (PROGRESS.md "Known Issues" items 1, 2, and the bundle-resource path issue):

1. **Device-change handler.** Subscribe to `AVAudioEngineConfigurationChangeNotification`. On notification: stop engine → disconnect all 8 player nodes → reconnect at new output format → restart engine. Per `AUDIO_NOTES.md` §"Device Changes" — the #1 source of production AVAudioEngine bugs.
2. **System-mute detection.** `AVAudioOutputNode.outputVolume` does not exist on macOS (the doc was iOS-shaped). Use CoreAudio: `kAudioDevicePropertyMute` on the default output device. Skip `play(...)` entirely when muted; increment `SessionStats.suppressedByMutedSystemCount` (added in Phase 5).
3. **`Bundle.module` pack resolution.** Currently `yellback-cli/main.swift` finds `Resources/Packs/crowd/` via cwd-relative path. Move the bundled pack to a path inside the Swift target's source tree (or declare it as a SwiftPM resource via `Package.swift`'s `resources:`). Use `Bundle.module` to resolve at runtime so distributed binaries work.

**Files to change:**

- `Sources/YellBackCore/Audio/SoundEngine.swift` — add `configurationChangeObserver` (NSNotification), the rebuild routine, the system-mute check at the top of `playInternal(...)`.
- `Package.swift` — declare `.process` resources for `Resources/Packs/crowd/` if going the resources route. Or, if going the in-target-source-tree route, move the directory into `Sources/YellBackCore/Resources/`.
- `Sources/yellback-cli/main.swift` — replace the cwd-relative pack path with `Bundle.module.url(forResource:withExtension:subdirectory:)`.
- `Tests/YellBackCoreTests/SoundEngineTests.swift` — add tests for the mute-skip path (mock CoreAudio property lookup), and a drift test that pins the configuration-change notification name.
- `Tests/YellBackCoreTests/PackLoaderTests.swift` — `testBundledCrowdPackParsesCleanly` already exists; verify it still works with `Bundle.module` lookup (might need the path resolution changed).

**Acceptance criteria:**

- `swift build` + `swift test` green; no test count regression.
- Distributed binary path: `swift build -c release && ./.build/release/yellback --config /tmp/blank.yaml --listen` (run from a non-repo directory) finds the bundled Crowd pack.
- System mute respected: `osascript -e 'set volume with output muted'` then trigger; no audio plays; `SessionStats.suppressedByMutedSystemCount` increments.
- Device-change handled cleanly on plug/unplug.

**Hardware-in-loop steps (mandatory):**

- User runs `--listen`, plays a trigger, hears audio. User plugs in headphones, plays another trigger, hears audio in headphones (not speakers). User unplugs, plays another trigger, hears audio in speakers again. No silent failure mode.
- User mutes system audio (Cmd-F10 or Control Center), triggers a sound, hears nothing. Unmutes; triggers a sound, hears it.

**Out of scope:**

- Multi-channel / surround sound packs.
- Per-output-device pack switching.

---

### Phase 6 — KeyboardDetector

**Status:** `pending`
**Depends on:** —

**Description.** Implement the third detector. Currently a one-line stub at `Sources/YellBackCore/Detectors/KeyboardDetector.swift`. Conforms to the existing `Detector` protocol. Reads keystroke timing via `CGEventTap`, computes keys-per-second over a rolling window of `rageType.rolling_window_seconds`, fires when rate ≥ `rageType.keystrokes_per_second_threshold`.

**Privacy invariant:** keystroke *content* is never read or buffered. Only the timestamp of each keydown event. Mirror the `precondition` pattern from `MicDetector` / `AccelerometerDetector`: expose `retainedKeystrokeContentByteCount` (must be `0`) and a runtime check inside `process(...)`.

**Permission:** Accessibility, granted via System Settings → Privacy & Security → Accessibility. `start()` returns `.needsPrivilegedAccess` if the tap can't be created; consumer prompts the user (CLI prints instructions; Mac app shows dialog). Note: unlike desk_bang, this is a *user-grantable* permission, not a sudo-only one.

**Files to create / change:**

- `Sources/YellBackCore/Detectors/KeyboardDetector.swift` — full implementation (currently a stub).
- `Sources/yellback-cli/main.swift` — wire it like the other two detectors. The placeholder `[trigger]` rage_type log line at line 165–167 already handles the disabled case; this phase replaces "skipping" with real wiring.
- `Sources/YellBackCore/Signals/TriggerEvent.swift` — `consoleLogLine` currently emits `keystrokes=?` placeholder for `.rageType` (per Trigger.swift logic and `TriggerTests.testConsoleLogLineForRageTypeUsesPlaceholderUntilDetectorImplemented`). Replace with the real value derived from `intensity` (inverse of the keystrokes-per-second → intensity mapping). Update the test name and assertion to pin the new format.
- `Tests/YellBackCoreTests/KeyboardDetectorTests.swift` — new file, parallels `MicDetectorTests` / `AccelerometerDetectorTests`. Synthetic keystroke streams (timestamps only, no content); rate calculation; sustain / cadence; rolling-window boundary; isEnabled gate; priming hook. Mirror the test structure: harness, fixtures (new `KeystrokeFixtures.swift`), boundary tests at the keystrokes/sec threshold, "natural typing does not trigger" test.
- `Tests/YellBackCoreTests/KeystrokeFixtures.swift` — new fixture helpers analogous to `MotionFixtures` / `AudioFixtures`. Build `[Date]` arrays for "natural typing at 4 cps", "rage typing at 12 cps", "burst-then-pause" patterns.

**Reuse, do not reinvent:**

- `Detector` protocol — conform exactly.
- `IntensitySignal`, `TriggerEvent` — already public.
- `RageTypeConfig` already in `EngineConfig.swift`.
- `Trigger.snakeCaseName` already returns `"rage_type"`.
- The privacy-invariant pattern (runtime `precondition` on retained data) — copy from `MicDetector`.

**Acceptance criteria:**

- `swift build` + `swift test` green; ~150+ tests (5+ new in KeyboardDetectorTests, plus updated `testConsoleLogLineForRageType…`).
- `--listen` mode shows `[trigger] rage_type intensity=… keystrokes=…` lines when typing fast enough, no lines when typing normally.
- Privacy invariant test passes: `retainedKeystrokeContentByteCount == 0` after thousands of keystrokes processed.
- New `DetectorError.needsPrivilegedAccess` path produces actionable CLI output ("System Settings → Privacy & Security → Accessibility") when Accessibility is denied.

**Hardware-in-loop steps:**

- User runs `--listen` for the first time, sees CLI prompt to grant Accessibility. User goes to System Settings, grants it, restarts `--listen`.
- User types a normal sentence at ~4 cps; nothing fires.
- User rage-types at ≥8 cps; `[trigger] rage_type` fires; sound plays.
- User mixes rage-typing with desk-banging; PrimingState multipliers apply correctly (visible in `[intensity]` debug logs if `logging.level: debug`).

**Out of scope:**

- Calibrating the per-user keystrokes/sec threshold (Phase 7).
- Distinguishing "typing" from "shortcut hotkey spam" — both count.

---

### Phase 7 — Calibration onboarding

**Status:** `pending`
**Depends on:** Phase 5 (engine API). Phase 6 is required only for the rage_type calibration leg; the desk_bang and scream legs can ship without Phase 6.

**Description.** Per-machine threshold calibration captured in a guided flow. Solves the architectural class-of-bug that produced the M2 1.5g-too-high finding: no shipped default fits every machine, so we stop shipping a single global default for tunables that vary by hardware / mic gain / ambient noise / user typing speed.

**Three legs:**

| Detector | Knob | Capture method |
|---|---|---|
| `scream` | `dbfs_threshold` | 5s ambient floor → 5s "speak normally" → 5s "shout" |
| `desk_bang` | `g_force_threshold` | 3× "natural tap" → 3× "firm tap" |
| `rage_type` | `keystrokes_per_second_threshold` | 5s "type at relaxed pace" → 5s "type as fast as you can" |

Calibration consumes the **continuous `IntensitySignal` stream** that every detector already emits. No new detector surface needed — that's exactly what the signal duality was forward-compat'd for.

**Per-detector recommendation math:**

- **`desk_bang`:** peak g-force delta from each "firm tap" sample → median × 0.8, clamped above (max of "natural taps" × 1.2 + 0.1g safety margin). User wants "firm but not aggressive" to fire; natural taps must NOT fire.
- **`scream`:** peak dBFS from "shout" window → midpoint between (speak-window 95th percentile) and (shout-window 5th percentile), biased 30% toward shout. Catches yelling without false-firing on talking.
- **`rage_type`:** 95th percentile of cps from "fast" window × 0.85. Matches the burstiness of real rage-typing without requiring sustained record-cadence.

All three formulas are tunable constants in `Calibrator.swift`, each pinned by a test on synthetic input.

**Engine API surface (additive, doesn't break v1):**

```swift
public extension YellBackEngine {
    /// Run a calibration session for the listed detectors. Detectors must be
    /// enabled in the active config; mic permission must already be granted
    /// for scream; sudo (or helper) for desk_bang; Accessibility for rage_type.
    func beginCalibration(
        for triggers: [Trigger],
        prompt: (CalibrationStep) async -> Void
    ) async throws -> CalibrationResult
}

public struct CalibrationResult {
    public let scream:    ScreamConfig?     // nil if not calibrated
    public let deskBang:  DeskBangConfig?
    public let rageType:  RageTypeConfig?
    public let timestamp: Date
    public let rawStats:  [Trigger: CalibrationStats]   // for diagnostics
}

public extension EngineConfig {
    /// Pure: returns a new config with calibrated leaves merged in.
    func applying(_ result: CalibrationResult) -> EngineConfig
}
```

**Files to create:**

- `Sources/YellBackCore/Calibration/Calibrator.swift` — orchestrator. Captures samples per step, hands to analyzer.
- `Sources/YellBackCore/Calibration/CalibrationStep.swift` — value type: `{ trigger, prompt: String, durationSeconds: Double }`.
- `Sources/YellBackCore/Calibration/CalibrationResult.swift` — `CalibrationResult` + `CalibrationStats` types.
- `Tests/YellBackCoreTests/CalibratorTests.swift` — synthetic intensity streams → asserted recommendations; one drift test per detector pinning the recommendation math; boundary case ("user shouts at speak volume → refuse to recommend").

**Files to change:**

- `Sources/YellBackCore/YellBackEngine.swift` — add `beginCalibration` extension.
- `Sources/YellBackCore/Config/EngineConfig.swift` — add `applying(_:)` extension.
- `Sources/yellback-cli/main.swift` — parse `--calibrate [<detector>...]`; drive prompts on stderr; print before/after diff; ask `apply? [y/N]`; write back to config file via Yams emitter (round-trip should preserve comments — test this).
- `CONFIG_SCHEMA.md` — document optional `calibration:` metadata block (timestamp, machine identifier, raw stats — for diagnostics + future "redo calibration in N days" prompts).

**Reuse, do not reinvent:**

- `IntensitySignal` and `Detector.onIntensitySignal` — already public, already emitted by all conforming detectors.
- `MicDetector.normalizedIntensity(fromDBFS:)` and `AccelerometerDetector.normalizedIntensity(fromGForceDelta:)` — invertible mappings the calibrator needs to go from intensity back to raw units. Currently `private` — Phase 7 makes them `internal` and adds inverse helpers.
- Throwing struct inits (`ScreamConfig`, `DeskBangConfig`, `RageTypeConfig`) — calibrated values pass through the same validation path; out-of-bounds recommendations throw at construction time, never silently land.
- `ConfigLoader` — read side. Add a `ConfigWriter` peer or a method on `EngineConfig` for write-back.

**Acceptance criteria:**

- `swift build` + `swift test` green; ~165+ tests (~15 new in CalibratorTests).
- `yellback --calibrate desk_bang` on M2: tap firmly when prompted; recommended `g_force_threshold` is < 1.5 (the documented-too-high default); apply; run `--listen`; natural taps now fire.
- `yellback --calibrate` (all three): completes for scream + desk_bang; if Phase 6 is complete, also for rage_type; otherwise prints "rage_type calibration unavailable until KeyboardDetector ships".
- "Empty samples" regression guard: calibration applied with no captured data is a no-op (does NOT zero out thresholds).
- "Boundary refusal" test: synthetic stream where user "shouts at speak volume" → calibrator refuses, returns diagnostic, doesn't pick a threshold.
- Config write-back round-trip preserves comments in `config.example.yaml` (test against the bundled file).

**Hardware-in-loop steps (mandatory):**

- User runs `yellback --calibrate desk_bang` on M2; performs prompted natural and firm taps.
- User runs `yellback --calibrate scream` in a quiet room; performs prompted speak and shout.
- User runs `yellback --calibrate` after Phase 6 lands, including the rage_type leg.
- For each: confirm recommended threshold "feels right" — natural taps don't fire post-calibration; firm taps do; conversation doesn't trigger scream; shouting does; normal typing doesn't trigger rage_type; angry typing does.

**Out of scope:**

- Re-calibration nag ("your calibration is 90 days old, re-do?"). Future enhancement.
- Per-environment profiles (`home`, `office`, `café`). Solvable with named config files later; nothing here precludes it.
- Cross-machine sync. Calibration is intentionally per-machine.
- ML or adaptive online thresholding. Brand promise is causal: "you scream, it yells back" — adaptive suppression breaks the contract on purpose.
- Calibrating `priming.threshold_multiplier` or `priming.window_seconds`. Cross-trigger UX knobs, not per-machine targets.

**On completion, update:**

- PROGRESS.md "Known Issues" #5 — replace with a backreference: "Per-machine calibration shipped in Phase 7; defaults remain baseline-sane but users should `yellback --calibrate` for best results".
- SESSION_HANDOFF.md §6 — remove the standalone "Calibration spike" entry.
- ARCHITECTURE.md — add a "Calibration as engine-level concern" subsection alongside "The Priming State" (both engine-owned, detector-agnostic state).

---

### Phase 12 — Real Crowd pack content (audio + text, CC0 / CC-BY)

**Status:** `pending`
**Depends on:** Phase 5c (text packs exist by then)
**Note:** content work, not engineering. Consider doing by hand or via the `content-engine` skill rather than the engineering-loop quality stack.

**Description.** Replace the 6 synthesised placeholder audio clips AND the placeholder text phrases at `Resources/Packs/crowd/` with real / curated content. Audio: real audience-reaction clips under CC0 or CC-BY 4.0 licenses. Text: curated phrase lists per tier (original or sourced under compatible terms). Update `ATTRIBUTIONS.md` per the table format the file establishes — both per-clip audio licensing AND per-phrase-set text licensing.

**Sources to evaluate:**

- freesound.org (filter `tag:crowd cheer license:CC0`)
- archive.org's audience-reaction collections
- BBC sound effects archive (license category-dependent — check each clip)
- Pixabay audio (CC0, but verify provenance)

**Files to change:**

- `Resources/Packs/crowd/clap_short_a.caf`, `clap_short_b.caf`, `cheer_mid_a.caf`, `cheer_mid_b.caf`, `roar_long_a.caf`, `roar_long_b.caf` — replace placeholders with sourced audio. Encode to mono Float32 .caf at 44.1 kHz to match the loader's output format.
- `Resources/Packs/crowd/text.yaml` — replace Phase 5c's placeholder phrases with the curated phrase lists per tier. Same schema; just better content. (Phase 12 may also bump phrase counts per tier — more variety = better no-repeat experience.)
- `ATTRIBUTIONS.md` — populate the per-clip audio table (Clip / Tier / Source / License / Attribution) AND the per-phrase-set text section (e.g. "Tier / Source / License / Attribution" with pointers to where the phrases came from). Verify every audio clip license; verify every text source license if any phrases come from outside.
- `Resources/Packs/crowd/pack.yaml` — no schema change needed; only filenames may change if you rename clips.

**Acceptance criteria:**

- All 6 audio clips ≤ 5 seconds (per `PackLoader.maxClipDurationSeconds`).
- All 6 audio clips parse cleanly: `testBundledCrowdPackParsesCleanly` passes.
- Bundled `text.yaml` parses cleanly under `TextPackLoader` (drift test from Phase 5c).
- Each tier (audio + text) is distinguishable (low = sharp/short, medium = mid-energy, high = sustained/loud — same axis applied to both modalities).
- `ATTRIBUTIONS.md` table populated; every audio clip license verified; text licensing documented.
- Manual A/B: trigger a desk_bang at low / medium / high intensity; user confirms each tier sounds "right" AND the matching `[yell-back]` phrase reads "right" (matched to the energy).

**Hardware-in-loop steps:** A/B listening test by user.

**Out of scope:**

- Premium pack content (paid Mac app concern).
- Spatial audio / surround mixing.

---

## Per-session contract

When `/prp-implement` runs against this PRD, it must, in order:

1. Read this PRD; pick the next phase whose status is `pending` and whose dependencies are all `complete`.
2. Spawn an Explore agent to verify nothing in the codebase has drifted since the phase was written.
3. Run `prp-plan` to produce `.claude/PRPs/plans/<phase-slug>.plan.md`.
4. TDD implement per the plan (tests first, run red, write code, run green) — use `tdd-workflow` / `tdd-guide`.
5. Run `code-review` agent on the diff. Address inline.
6. Run `security-review` agent if any of these paths were touched:
   - `Sources/YellBackCore/Detectors/AccelerometerDetector.swift`
   - `Sources/YellBackCore/Detectors/MicDetector.swift`
   - `Sources/YellBackCore/Detectors/KeyboardDetector.swift` (once it exists)
   - `Sources/YellBackCore/Audio/`*
   - `Sources/YellBackCore/Calibration/`* (once it exists; config-write paths)
7. Run `silent-failure-hunter` on the diff.
8. Run `verification-loop`: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Both green or the session does NOT commit.
9. If the phase has hardware-in-loop steps, prompt the user, wait for confirmation. If user reports failure, leave phase as `pending` (NOT `complete`); append diagnostic notes to the phase entry.
10. Update PROGRESS.md (Session count, test count breakdown, Session History entry, Next Session). Update SESSION_HANDOFF.md if the next-session pointer or known-issues priority shifted.
11. `prp-commit` (3-5 commits per session, broken into types → impl → tests → docs). HEREDOC format. Co-Authored-By trailer.
12. Fast-forward `main`, push.
13. Mark this phase `complete` in this PRD; save.

## Quality stack (applies to every phase)

Encoded in `CLAUDE.md` "ECC Handoff Conventions". TDD via `tdd-workflow`. Code review via `code-review` agent. Security review via `security-review` agent on relevant paths. Silent-failure check via `silent-failure-hunter`. Build + test green via `verification-loop`. No commit if any gate fails.

## Footguns (do NOT regress)

Full list in `SESSION_HANDOFF.md` §7. The IOKit / AVAudioEngine ones in particular bit during Sessions 3+7 and Session 4 — re-read before any work in those areas.

- No `kIOHIDOptionsTypeSeizeDevice`.
- No per-device `IOHIDDeviceOpen` / `IOHIDDeviceScheduleWithRunLoop` on top of manager-level open.
- No `CMMotionManager` (`API_UNAVAILABLE(macos)`).
- No `load(fromByteOffset:as:)` for HID offsets 6/10/14 (use `loadUnaligned`).
- No allocating `AVAudioPlayerNode` at trigger time.
- No reinstantiating `AVAudioEngine` on config change.
- No squashing the three `WIP:` IOKit-debugging commits (`1c411bb`, `7dcec43`, `3225fcd`).
- No removing the `precondition(retainedAudioSampleCount <= 8)` privacy invariant in `MicDetector` (it IS the privacy enforcement; security-review must not flag it as "unused").
- No removing the `onIntensity` API (forward-compat for v2 fusion module).

## Out of scope for this PRD

- yellback-mac (private repo; separate ECC handoff later).
- Landing site, contributor docs site (not in any current repo).
- App Store packaging, code signing, notarization (yellback-mac concern).
- Telemetry / analytics / crash reporting (architecturally forbidden; see ARCHITECTURE.md "What's NOT in This Architecture").
- Cross-platform (Windows / Linux) port — v2 in `yellback-core-rs`, not this repo.
- Premium pack content sourcing (paid app concern).
