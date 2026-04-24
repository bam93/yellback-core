# Progress Log — yellback-core

This file is the primary handoff artifact between Claude Code sessions. Every session reads this at start and updates it at end.

## Current State

**Session count:** 1
**Build status:** `swift build` green (Yams 5.4.0 resolved)
**Test status:** `swift test` green — 1 test passing
**Last updated:** 2026-04-24

## Summary

Session 1 landed the Swift Package scaffold. `Package.swift`, the full `Sources/` tree, `Tests/`, a trivial passing test, `config.example.yaml`, `.gitignore`, and `ATTRIBUTIONS.md` all exist. Public API surface (types from ARCHITECTURE.md lines 47-80) is sketched with doc comments and empty bodies — no detector, audio, or config logic is implemented yet. The package compiles cleanly and one trivial test passes.

## What Has Been Completed

- Repository harness: CLAUDE.md, ARCHITECTURE.md, AUDIO_NOTES.md, CONFIG_SCHEMA.md, README.md, LICENSE, PROGRESS.md
- `Package.swift`: `swift-tools-version:5.9`, `platforms: [.macOS(.v14)]`, library target `YellBackCore`, executable product `yellback` (target `yellback-cli`), test target, Yams `.upToNextMajor(from: "5.0.0")`
- Public API stubs for the types listed in ARCHITECTURE.md: `YellBackEngine`, `EngineConfig`, `Trigger`, `TriggerEvent`, `IntensitySignal`, `PermissionState`, `PermissionStatus`
- Internal type stubs (doc comments only, no bodies): `MicDetector`, `KeyboardDetector`, `AccelerometerDetector`, `SoundEngine`, `SoundPack`, `ConfigLoader`, `SessionStats`, `PrimingState`
- `yellback-cli/main.swift`: prints "not yet implemented" placeholder
- `config.example.yaml`: mirrors `CONFIG_SCHEMA.md` exactly
- `Tests/YellBackCoreTests/YellBackCoreTests.swift`: one trivial passing test
- `ATTRIBUTIONS.md`: headers-only scaffold; Crowd pack table row is `tbd`
- `Resources/Packs/crowd/.gitkeep` keeps the empty pack dir under version control
- `.gitignore` excludes `.build/`, `.swiftpm/`, `DerivedData/`, `*.xcodeproj`, `xcuserdata/`, `.DS_Store`
- `LICENSE` holder updated to "Baaden Scientific / Marc Baaden"

## What Is In Flight

Nothing — session 1 is clean closed.

## Known Issues

- **`swift test` requires full Xcode, not just Command Line Tools.** On machines where `xcode-select -p` points at `/Library/Developer/CommandLineTools`, `XCTest` is not on the module search path and `swift test` fails. Workaround: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`, or run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once. This is a standard macOS SwiftPM caveat — document it in README when we get to a release-prep session, not now.
- The original `PROGRESS.md` next-session checklist listed "Create LICENSE" and "Create README.md", but both shipped with the harness commit. The checklist is now accurate (session 1 updated/kept them rather than creating).

## Next Session (Session 2)

**Recommended scope — pick ONE, not all:**

Option A — **ConfigLoader + full config types (recommended first).** Reason: every detector and the audio engine will need typed config in their initializers. Doing config first unblocks everything. Deliverables:
1. Flesh out `EngineConfig` with nested structs (`TriggersConfig`, `ScreamConfig`, `RageTypeConfig`, `DeskBangConfig`, `PrimingConfig`, `AudioConfig`, `LoggingConfig`)
2. Implement `ConfigLoader` using Yams — `static func load(from url: URL) throws -> EngineConfig`
3. Enforce all validation rules from `CONFIG_SCHEMA.md` lines 136-148 with clear error messages
4. Add tests: valid example loads, each validation rule fails as expected, malformed YAML fails cleanly
5. Wire `yellback-cli/main.swift` to load `--config <path>` and print the parsed config — still no detectors

Option B — **MicDetector with synthetic-audio tests.** The riskiest piece technically; doing it early de-risks the rest. Requires recording or synthesizing test `.caf` fixtures.

Option C — **SoundEngine + clip playback with the Crowd pack sourced.** Needs CC0/CC-BY clips sourced first.

**Do not attempt in session 2:**
- More than one of the above
- Wiring detectors to the audio engine (that's session 3+)
- Priming state (engine-level, belongs after at least one detector exists)

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

## Session History

- **Session 1 — 2026-04-24 — Scope: bootstrap the Swift Package scaffold.** Outcome: `swift build` and `swift test` both green. Public API stubs cover every type from ARCHITECTURE.md's public-API section. No detector/audio/config *logic* yet — bodies are empty, stubs are bodies-only where the type has no public methods.
