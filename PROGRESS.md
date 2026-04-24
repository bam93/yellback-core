# Progress Log — yellback-core

This file is the primary handoff artifact between Claude Code sessions. Every session reads this at start and updates it at end.

## Current State

**Session count:** 0 (repository not yet started)
**Build status:** N/A — no code yet
**Test status:** N/A — no tests yet
**Last updated:** [date of first commit]

## Summary

This repository is the OSS Swift Package component of YellBack. At the moment, only harness files exist (CLAUDE.md, ARCHITECTURE.md, etc.). No Swift code has been written.

## What Has Been Completed

- Repository harness: CLAUDE.md, ARCHITECTURE.md, AUDIO_NOTES.md, CONFIG_SCHEMA.md, this file
- Architectural decisions are locked (see ARCHITECTURE.md)
- Config schema is specified (see CONFIG_SCHEMA.md)

## What Is In Flight

Nothing — this is session zero.

## Known Issues

None yet.

## Next Session

**Scope:** bootstrap the Swift Package. Specifically:
1. Create `Package.swift` with two targets: `YellBackCore` (library) and `yellback-cli` (executable)
2. Add Yams as a dependency (`https://github.com/jpsim/Yams`, latest 5.x)
3. Create empty source files matching the layout in CLAUDE.md's "Code Organization" section — stubs with doc comments, no implementation
4. Create `config.example.yaml` matching CONFIG_SCHEMA.md exactly
5. Create `Tests/YellBackCoreTests/YellBackCoreTests.swift` with one trivial passing test
6. Create `LICENSE` (MIT, holder: [Marc's chosen entity])
7. Create `README.md` — user-facing, covers: what YellBack is, one-paragraph install + run instructions for the CLI, link to ARCHITECTURE.md for contributors
8. Create `ATTRIBUTIONS.md` as an empty scaffold — will be populated when Crowd pack audio is sourced
9. Confirm `swift build` and `swift test` both pass
10. Commit everything with the message "Initial package scaffold — compiles, one trivial test passes"

**Do not attempt in this session:**
- Implementing any detector logic
- Sourcing audio clips
- Writing substantive tests
- Setting up CI

**Budget check:** this scope should fit well within one context window. If you find yourself running short, stop and commit what works — don't rush to "finish."

## Architecture Decisions Log

(Append new decisions here as sessions progress. Each entry: date, decision, rationale, session that made it.)

- **[initial]** Two-repo architecture: this repo (public, MIT) + `yellback-mac` (private). Rationale: OSS contributors see clean MIT code; paid app code stays private. See conversation brief.
- **[initial]** No UI framework imports in the core. Rationale: keeps future Rust/Tauri port as translation rather than redesign.
- **[initial]** Detectors emit both discrete events AND continuous intensity signals. Rationale: v1 audio engine uses events; v2 fusion module will use signals. Both live from v1 onward.
- **[initial]** Priming state lives on the engine, not on individual detectors. Rationale: cross-trigger behaviour is engine-level state.
- **[initial]** `.caf` audio format for bundled clips. Rationale: lowest decode latency of formats AVAudioEngine supports.

## Session History

(Each completed session appends an entry here. Format: date, session number, scope, outcome.)

*No sessions yet.*
