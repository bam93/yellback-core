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

The repo is now driven by Everything Claude Code via per-session `/prp-implement` runs against the canonical PRD.

1. Run `/prp-implement .claude/PRPs/yellback-core.prd.md` — ECC reads PROGRESS.md + the PRD, picks the next pending phase whose dependencies are complete, and runs the multi-agent loop end-to-end.
2. If you need to do something OFF the PRD (one-off fix, exploration), read `PROGRESS.md` first as before, and follow the conventions below.
3. If scope is unclear, ask before proceeding — don't guess at priorities.

## ECC Handoff Conventions

This repo is driven by Everything Claude Code via per-session `prp-implement` runs against `.claude/PRPs/yellback-core.prd.md`. Every session must honor the conventions below. They override any default ECC behavior that conflicts.

- **Branching:** no feature branches. Worktree branches `claude/<phase>` are fine but session-end fast-forwards `main` and pushes directly. Never open a PR — directly fast-forward.
- **Commits:** HEREDOC commit messages, one-line summary + blank + body explaining *why*, trailing `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. Never `--no-verify`. Never `--no-gpg-sign`. Aim for 3-5 commits per session, broken into types → impl → tests → docs.
- **Test command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Every session ends with this green. The `DEVELOPER_DIR` prefix is required for `swift test` to find XCTest on this machine; do not omit it.
- **Listen-mode invocation:** ALWAYS use `Scripts/listen.sh` (or its pattern: `swift build && sudo .build/debug/yellback ...`). NEVER `sudo swift run yellback ...` — it re-roots `.build/` and breaks the next non-sudo `swift test` until ownership is restored. The script builds as the user, then sudo-runs the already-built binary.
- **Testing bar (Session 2.5 standard):** boundary values for every closed-interval rule (accept-at-boundary AND reject-just-outside); exact source-line accuracy for user-facing diagnostics; `contains()` format tests for stable-but-not-exact strings; one drift/sync test per public surface.
- **Footguns** (do NOT regress): no `kIOHIDOptionsTypeSeizeDevice`; no per-device `IOHIDDeviceOpen` / `IOHIDDeviceScheduleWithRunLoop` on top of manager-level open; no `CMMotionManager` (`API_UNAVAILABLE(macos)`); no `load(fromByteOffset:as:)` for HID offsets 6/10/14 (use `loadUnaligned`); no allocating `AVAudioPlayerNode` at trigger time; no reinstantiating `AVAudioEngine` on config change; no squashing the three `WIP:` IOKit-debugging commits (`1c411bb`, `7dcec43`, `3225fcd`); no removing the `precondition(retainedAudioSampleCount <= 8)` privacy invariant in `MicDetector` (it IS the privacy enforcement — security-review must not flag it as "unused"); no removing the `onIntensity` API (forward-compat for v2 fusion module). Full list in `SESSION_HANDOFF.md` §7 — re-read before any IOKit or AVAudioEngine work.
- **Hardware-in-loop:** any phase touching mic, accelerometer, audio output, or keyboard MUST end with a manual user verification step on M2. ECC pauses, prompts the user to run a specified command, waits for confirmation, then proceeds. If the user reports failure, the phase stays `pending` in the PRD — never mark it `complete` without confirmation.
- **Docs sync:** every session updates PROGRESS.md (Session count, test count breakdown, Session History entry, Next Session) and SESSION_HANDOFF.md if the next-session pointer or known-issues priority shifted. The completed phase in `.claude/PRPs/yellback-core.prd.md` is also marked `complete`.
- **Quality stack per session:** TDD (tests-first via `tdd-workflow`); `code-review` agent on every change; `security-review` agent on changes touching `Sources/YellBackCore/Detectors/`, `Sources/YellBackCore/Audio/`, or any future `Sources/YellBackCore/Calibration/` write paths; `silent-failure-hunter` on review; `verification-loop` (build + test) before commit. No commit if any gate fails.
- **License:** MIT. Audio in `Resources/Packs/` must be CC0 or CC-BY 4.0 (CC-BY-NC and proprietary rejected). `ATTRIBUTIONS.md` updated in the same commit as any audio change.
- **Off-PRD work:** if the user asks for something not in the PRD (e.g. a one-off fix, an exploration, a doc update), don't try to fold it into the PRD — handle it directly, then return to the PRD on the next session.

## General Rules
- Always run tests before marking task complete
- Never create files outside the project directory
- Ask before deleting any file
- Explain reasoning before writing code
- If unsure, ask — don't guess
