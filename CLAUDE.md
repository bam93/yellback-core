# YellBack Core

## Project Purpose

YellBack is a cathartic companion app: it detects physical signs of frustration (screaming, rage-typing, desk-banging) and responds by playing sounds that match your energy. It doesn't calm users down — it matches their rage.

`yellback-core` is the open-source (MIT-licensed) Swift Package that provides the detection engine and audio playback. It is consumed by `yellback-mac` (the private paid Mac app) and runs standalone as a headless CLI for technical users. This repository must remain usable as both.

Success for this repo means: a contributor clones it, runs `swift build`, runs `yellback --config config.example.yaml`, and the app starts yelling back at them within 30 seconds.

## Architecture Principles

Three non-negotiable rules govern this codebase:

1. **No UI frameworks.** This package imports Foundation, AVFoundation, CoreMotion, CoreGraphics (for CGEventTap), and Yams. It does NOT import AppKit, SwiftUI, UIKit, or Combine for UI purposes. This is what makes it portable to a future Rust/Tauri port on Windows/Linux (v2).

2. **The core never knows who's calling it.** Whether invoked by the CLI daemon or by the paid Mac app, behaviour is identical. UI concerns — menu bars, settings panels, stats dashboards — live entirely in the consumer. The core exposes events and intensity signals; the consumer decides what to do with them.

3. **Detectors emit continuous intensity signals, not just discrete trigger events.** This is the single most important architectural decision. v1's audio engine consumes discrete events. v2's planned multimodal fusion consumes the continuous signals. Both APIs are live from v1 onward. Do not remove `onIntensity` to simplify.

## Code Organization

```
Sources/
  YellBackCore/          # Library target (consumed by yellback-mac)
    Detectors/           # AccelerometerDetector, MicDetector, KeyboardDetector
    Signals/             # IntensitySignal, PrimingState
    Audio/               # SoundEngine, SoundPack
    Config/              # ConfigLoader (YAML via Yams)
    Stats/               # SessionStats (counters only, no UI)
    YellBackEngine.swift # Public entry point
  yellback-cli/          # Executable target (headless daemon)
    main.swift
Resources/Packs/crowd/   # Bundled default sound pack (MIT-compatible audio)
Tests/YellBackCoreTests/
```

## Universal Development Principles

- **Concurrency:** audio and motion callbacks arrive on background threads. `@MainActor` is NOT used in this package (no UI). Use `DispatchQueue` or Swift concurrency with explicit queue management.
- **Latency budget:** trigger to first audio must stay under 100ms. Preload pack clips at pack-switch time, never at trigger time. Use a pool of ~8 `AVAudioPlayerNode`s to handle rapid consecutive triggers without allocation.
- **Tests are required for detectors.** Each detector has a unit test that feeds synthetic input (recorded audio samples, simulated keystroke streams, simulated motion events) and asserts trigger behaviour. Detection tuning changes require updated tests.
- **Config is validated at load.** YAML errors exit non-zero with a clear message. Don't fail silently, don't apply partial config.
- **Privacy is architectural, not a marketing claim.** The keyboard detector reads key timing only, never key content. The mic detector computes RMS + band-pass, never records. If code would need to change for this to be false, that change is rejected.

## Progressive Disclosure: Where to Find More

Before writing detection code, read `ARCHITECTURE.md` — it covers the signal/event model and why the priming state works the way it does.

Before modifying audio playback, read `AUDIO_NOTES.md` — it covers AVAudioEngine pitfalls (device changes, interruptions) and the clip-preloading strategy.

Before changing the config schema, read `CONFIG_SCHEMA.md` — it's the canonical reference for the YAML format and needs to stay in sync with `config.example.yaml`.

When starting a new session, read `PROGRESS.md` first. It documents what the previous session completed, what's in flight, and what this session should focus on.

## Session Workflow

This repository is developed across multiple Claude Code sessions. Each session must maintain continuity with the previous one.

**At the start of every session:**
1. Read `PROGRESS.md` to understand current state
2. Run `swift build` and `swift test` to confirm the repo is in a working state
3. Review the most recent git commits to see what was last done
4. Confirm what this session's scope is before writing code

**At the end of every session:**
1. Ensure `swift build` and `swift test` both pass
2. Commit all changes with descriptive messages (explain *why*, not just *what*)
3. Update `PROGRESS.md`: what was accomplished, what's left, what the next session should focus on, any known issues
4. If architectural decisions were made, update `ARCHITECTURE.md`

**Scope discipline:** don't attempt more than one major component per session. "Build the MicDetector with tests" is a session. "Build all three detectors" is not. When in doubt, do less and leave clear notes.

## Platform Scope

v1 is **macOS 14+ only**. A future v2 port to Windows/Linux via Rust/Tauri is planned but deliberately out of scope for this repository as it currently stands. If you find yourself writing code for Windows/Linux compatibility, stop — that belongs in a future `yellback-core-rs` sibling project, not here.

## Permissions

Two macOS permissions are required at runtime:
- **Microphone** — for the scream detector
- **Accessibility** — for `CGEventTap` in the rage-type detector

The core surfaces permission state via its public API. It does not prompt for permissions itself (that's the consumer's job — CLI prints instructions, Mac app shows dialogs).

## License

MIT. All audio clips in `Resources/Packs/crowd/` must be CC0 or CC-BY compatible. See `ATTRIBUTIONS.md` for the per-clip license record. If you add or replace a clip, update `ATTRIBUTIONS.md` in the same commit.

## Getting Oriented in This Session

1. Read `PROGRESS.md` for current state
2. Check the current session's scope in `PROGRESS.md` under "Next Session"
3. If scope is unclear, ask before proceeding — don't guess at priorities
