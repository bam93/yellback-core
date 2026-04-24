# Progress Log — yellback-core

This file is the primary handoff artifact between Claude Code sessions. Every session reads this at start and updates it at end.

## Current State

**Session count:** 2
**Build status:** `swift build` green (Yams 5.4.0 resolved)
**Test status:** `swift test` green — 24 tests passing (1 scaffold smoke test + 23 ConfigLoader tests)
**Last updated:** 2026-04-24

## Summary

Session 2 implemented the config layer. `EngineConfig` is now a tree of typed, Equatable structs (`TriggersConfig`/`ScreamConfig`/`RageTypeConfig`/`DeskBangConfig`/`PrimingConfig`/`AudioConfig`/`LoggingConfig` + `LogLevel`), each with defaults matching `config.example.yaml`. `ConfigLoader.load(from:)` and `.loadFromString(_:)` parse YAML via Yams into this tree, returning a `LoadResult` with `(config, warnings: [ConfigWarning])`. Every validation rule from `CONFIG_SCHEMA.md` lines 137-147 is enforced with typed `ConfigError` cases, and malformed YAML carries line numbers where Yams provides them. The CLI now accepts `--config <path>` and prints the parsed config. Session 1 still stands: public API surface unchanged (aside from `EngineConfig` growing from an empty struct to the nested tree).

## What Has Been Completed

**From Session 1:**

- Repository harness: CLAUDE.md, ARCHITECTURE.md, AUDIO_NOTES.md, CONFIG_SCHEMA.md, README.md, LICENSE, PROGRESS.md, ATTRIBUTIONS.md scaffold
- `Package.swift`: `swift-tools-version:5.9`, `platforms: [.macOS(.v14)]`, library target `YellBackCore`, executable product `yellback` (target `yellback-cli`), test target, Yams `.upToNextMajor(from: "5.0.0")`
- Public API stubs for `YellBackEngine`, `Trigger`, `TriggerEvent`, `IntensitySignal`, `PermissionState`, `PermissionStatus`
- Internal type stubs (doc comments only): `MicDetector`, `KeyboardDetector`, `AccelerometerDetector`, `SoundEngine`, `SoundPack`, `SessionStats`, `PrimingState`
- `Resources/Packs/crowd/.gitkeep`, `.gitignore`, LICENSE holder "Baaden Scientific / Marc Baaden"

**From Session 2:**

- `Sources/YellBackCore/Config/EngineConfig.swift` — `EngineConfig` now owns a full tree of typed, `Equatable` configs. Every nested struct has defaults matching `config.example.yaml`, plus a memberwise public `init(...)`.
- `Sources/YellBackCore/Config/ConfigError.swift` — typed `ConfigError: Error, Equatable, CustomStringConvertible` with cases `.malformedYAML`, `.invalidValue`, `.missingRequired`, `.fileUnreadable`. Descriptions render 1-based line numbers.
- `Sources/YellBackCore/Config/ConfigWarning.swift` — `ConfigWarning.unknownKey(path:line:)`, returned alongside the config rather than printed from inside the loader.
- `Sources/YellBackCore/Config/ConfigLoader.swift` — public `ConfigLoader.load(from:)` / `.loadFromString(_:)` → `LoadResult(config:, warnings:)`. Walks the Yams `Node` tree so validation errors carry line numbers. Enforces every rule from `CONFIG_SCHEMA.md` lines 137-147 except the `packs_directory` disk check, which is deferred to `YellBackEngine.start()` (Session 2 decision: keep loader hermetic).
- `Sources/yellback-cli/main.swift` — hand-rolled `--config <path>` / `--help` / `-h` parsing; prints a config summary on success, writes `ConfigError` description to stderr and exits non-zero on failure. No `swift-argument-parser` dependency yet.
- `Tests/YellBackCoreTests/ConfigLoaderTests.swift` — 23 tests: happy path loads real `config.example.yaml`; one test per validation rule; missing-key, malformed-YAML, and empty-file failures; omitted detector block → `enabled: false`; omitted field → default; `master_volume: null` follows system; unknown top-level and sub-block keys warn but still load.
- `EngineConfig` moved out of `YellBackEngine.swift` into `EngineConfig.swift`. `YellBackEngine.swift` shrinks to just the engine class + `PermissionState`/`PermissionStatus`.

## What Is In Flight

Nothing — session 2 is clean closed.

## Known Issues

- **`swift test` requires full Xcode, not just Command Line Tools.** On machines where `xcode-select -p` points at `/Library/Developer/CommandLineTools`, `XCTest` is not on the module search path and `swift test` fails. Workaround: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`, or run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once. This is a standard macOS SwiftPM caveat — document it in README when we get to a release-prep session, not now.
- The original `PROGRESS.md` next-session checklist listed "Create LICENSE" and "Create README.md", but both shipped with the harness commit. The checklist is now accurate (session 1 updated/kept them rather than creating).

## Next Session (Session 3)

**Recommended scope: `MicDetector` with synthetic-audio tests.** Reason: the microphone scream detector is the riskiest detector technically (real-time AVAudioEngine tap, RMS, band-pass, sustain logic) — derisking it early means Sessions 4-5 can focus on audio output and orchestration rather than re-litigating detection tuning. Also unblocks the end-to-end scream→sound flow, which is the most viscerally useful demo.

**Deliverables:**
1. `MicDetector` class owning an `AVAudioEngine` input tap. Consumes `ScreamConfig` in its init.
2. Compute RMS per buffer; apply 200Hz-3kHz band-pass when `voiceBandFilter == true`. Convert RMS to dBFS.
3. Emit a continuous `IntensitySignal` at a sensible sample rate (proposal: ~20 Hz, one signal per ~50ms of audio) via a consumer-supplied callback.
4. Emit a discrete `TriggerEvent` when dBFS has stayed above `dbfsThreshold` for at least `sustainSeconds`, respecting `cooldownSeconds`.
5. Synthetic-audio test fixtures under `Tests/YellBackCoreTests/Fixtures/` — pre-recorded / generated `.wav` or raw-PCM samples for a "shout," a "quiet-room," and a "loud-but-short clap." Unit tests feed these into the detector and assert trigger timing + intensity ranges.
6. Do NOT yet wire `MicDetector` into `YellBackEngine.start()` — that wiring is Session 5. Session 3 only needs the detector and its tests.

**Design questions to resolve at the start of Session 3:**
- Buffer size / sample rate for the input tap (affects latency vs CPU).
- Band-pass implementation: `AVAudioUnitEQ`, a hand-rolled biquad, or vDSP? vDSP is probably the right call for <100ms latency.
- Fixture generation: record once from a real mic, OR synthesize in Swift (sine wave + noise) and commit the generator script? Synthesising is more reproducible in CI and doesn't require hardware.
- Privacy invariant: the RMS/band-pass pipeline must never buffer more than N ms of audio. Pick N, enforce via an assert in tests.

**Do not attempt in Session 3:**
- KeyboardDetector or AccelerometerDetector (Sessions 4+ after audio is grounded)
- SoundEngine or audio playback (Session 4)
- Wiring anything into YellBackEngine (Session 5)
- Sourcing Crowd pack audio (Session 4)
- Priming state (Session 5 at earliest)

**Tentative order for later sessions:** Session 4 = `SoundEngine` + source the Crowd pack; Session 5 = wire scream→sound through `YellBackEngine` + introduce `PrimingState`; Session 6 = `KeyboardDetector`; Session 7 = `AccelerometerDetector`.

## Architecture Decisions Log

(Append new decisions here as sessions progress. Each entry: date, decision, rationale, session that made it.)

- **[initial]** Two-repo architecture: this repo (public, MIT) + `yellback-mac` (private). Rationale: OSS contributors see clean MIT code; paid app code stays private. See conversation brief.
- **[initial]** No UI framework imports in the core. Rationale: keeps future Rust/Tauri port as translation rather than redesign.
- **[initial]** Detectors emit both discrete events AND continuous intensity signals. Rationale: v1 audio engine uses events; v2 fusion module will use signals. Both live from v1 onward.
- **[initial]** Priming state lives on the engine, not on individual detectors. Rationale: cross-trigger behaviour is engine-level state.
- **[initial]** `.caf` audio format for bundled clips. Rationale: lowest decode latency of formats AVAudioEngine supports.
- **[session 1 / 2026-04-24]** `Package.swift` uses `swift-tools-version:5.9` rather than 5.10 or 6.0. Rationale: 5.9 is the first Swift toolchain shipped with Xcode 15, which is the first Xcode available on macOS 14 (our minimum). This maximises the range of macOS 14+ users who can build the package without upgrading Xcode.
- **[session 1 / 2026-04-24]** Executable product name is `yellback`, target dir/name is `yellback-cli`. Rationale: users run `yellback` at the shell; the source dir name reflects what kind of code it is. Decoupling product name from target name is the standard SwiftPM pattern for this.
- **[session 1 / 2026-04-24]** `Trigger` and `TriggerEvent` live under `Sources/YellBackCore/Signals/` alongside `IntensitySignal` and `PrimingState`. CLAUDE.md's "Code Organization" only explicitly lists `IntensitySignal` and `PrimingState` in `Signals/` but keeping all event- and signal-shaped types together is the natural grouping; the CLAUDE.md comment was descriptive, not exhaustive.
- **[session 1 / 2026-04-24]** `Package.resolved` is committed. Rationale: this is the standard SwiftPM guidance for any package that ships an executable product (locks Yams version for reproducible builds of the CLI). If the lockfile ever causes contributor friction we can revisit.
- **[session 2 / 2026-04-24]** Every config field has a documented default sourced from `config.example.yaml`. Missing individual fields inside a present block are silently filled with defaults (not rejected). Rationale: consistent with the "whole detector block omittable → enabled:false" semantics already in the schema, and friendlier to users hand-editing partial configs. The canonical source of truth for default values is the `public init(...)` parameter defaults on each nested config struct.
- **[session 2 / 2026-04-24]** Unknown keys never fail — they surface as `ConfigWarning.unknownKey`, including nested paths (e.g. `triggers.scream.unknown_tweak`). Rationale: forward-compat. Older binaries running a newer user's config should degrade gracefully rather than refuse to start. The schema's original "unknown top-level keys warn" rule is applied recursively.
- **[session 2 / 2026-04-24]** `ConfigLoader` does NOT hit the filesystem to validate `packs_directory` at load time (though the schema rule says unreadable/uncreatable paths should fail loading). Rationale: keeps `ConfigLoader` hermetic and its tests pure. The check is deferred to `YellBackEngine.start()`, which is where we first actually need to read the directory. The rule will still be enforced — just later.
- **[session 2 / 2026-04-24]** Warnings are returned in `LoadResult.warnings` rather than `print`ed from inside the loader. Rationale: testability (XCTest can assert on the warning list) and separation of concerns (CLI decides stderr formatting; paid app decides UI rendering).
- **[session 2 / 2026-04-24]** `ConfigLoader` walks the Yams `Node` tree manually rather than using `YAMLDecoder` + `Codable`. Rationale: gives us per-node `mark.line` for precise validation error locations, and lets us distinguish "field missing" from "field null" without surrogate sentinel types. The cost is ~300 lines of hand-written traversal, but the tree is shallow and static, and the parsers are trivial once primitives are factored out.
- **[session 2 / 2026-04-24]** `yellback-cli` uses hand-rolled `CommandLine.arguments` parsing rather than adopting `swift-argument-parser`. Rationale: the current CLI surface is just `--config <path>` + `--help`; a dependency for that would be overkill. Revisit when we add a second real flag (e.g. `--pack`, `--self-test`).
- **[session 2 / 2026-04-24]** All config types are `Equatable`. Rationale: makes test assertions trivial (`XCTAssertEqual(config, EngineConfig())` etc.), and is a reasonable promise to callers who want to diff configs in the paid app's settings UI. `PermissionStatus` is still NOT `Equatable` — belongs to a different session when we wire permissions.

## Session History

- **Session 1 — 2026-04-24 — Scope: bootstrap the Swift Package scaffold.** Outcome: `swift build` and `swift test` both green. Public API stubs cover every type from ARCHITECTURE.md's public-API section. No detector/audio/config *logic* yet.
- **Session 2 — 2026-04-24 — Scope: `ConfigLoader` + typed `EngineConfig`.** Outcome: 24 tests passing (1 scaffold + 23 ConfigLoader). `yellback --config config.example.yaml` prints a full parsed summary and exits 0. All validation rules from `CONFIG_SCHEMA.md` enforced except the deferred `packs_directory` disk check. No detector work.
