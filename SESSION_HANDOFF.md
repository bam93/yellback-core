# Session Handoff — yellback-core

**Exhaustive reorientation doc.** If you're picking up this repo (human or agent) read this end-to-end. Includes everything that exists in conversation but might not have made it into other repo files. For long-form architectural rationale, see `PROGRESS.md`.

---

## 1. You are here

- **Repo:** `yellback-core` — open-source Swift Package, the detection engine for [YellBack](https://yellback.app). Consumed by a separate (private) `yellback-mac` repo for the paid app.
- **GitHub:** `github.com/bam93/yellback-core`. Owner: user goes by `bam93` on GitHub. Pushes use a PAT embedded in the remote URL — visible in `git remote -v`. **Heads up:** rotate that PAT at convenient maintenance time; it's been visible in this conversation's tool output. Switching to a credential helper or a deploy key would harden things.
- **Branch:** `main`.
- **Last commit on `origin/main`:** `c9d06ea` — _"Add bundled Crowd placeholder pack + generator script + close out PROGRESS"_.
- **Last session completed:** **Session 4** (audio output stack — `SoundEngine`, `SoundPack`, `PackLoader`, CLI wiring, bundled Crowd placeholder pack).
- **Test count:** **135 green**.
- **Working tree:** clean. Confirmed on 2026-04-26 by `git status --short`.
- **Worktree path** (for the agent that wrote this): `/Users/claude/Desktop/dev/yellback-core/.claude/worktrees/heuristic-murdock-54f91d/`. Main checkout at `/Users/claude/Desktop/dev/yellback-core/`.

## 2. Verification status

| Path | Tested by | Verified? |
|---|---|---|
| `swift build` | CI / agent | ✅ |
| `swift test` (135 tests) | CI / agent | ✅ |
| `yellback --config config.example.yaml` (config-print mode, exits) | agent + user manual run | ✅ |
| `sudo yellback --config config.example.yaml --listen` — scream detection prints `[trigger] scream …` | user on M2, 2026-04-25 | ✅ |
| `sudo yellback --config config.example.yaml --listen` — desk-bang detection prints `[trigger] desk_bang …` from physical taps | user on M2, 2026-04-26 (after the SPU wake fix landed) | ✅ |
| **Audio playback through SoundEngine — sound actually heard from speakers** | user on M2, 2026-04-26 — Crowd clip plays as expected on tap | ✅ |
| **Desk-bang threshold tuning** | user on M2, 2026-04-26 — reports 1.5g default is too high; natural taps don't fire, only firm slams. **Direction: lower the default.** First real empirical data point for cheat audit #5 (calibration). | ⚠️ needs calibration session |

### Verified end-to-end on 2026-04-26 (M2)

`sudo swift run yellback --config config.example.yaml --listen` — user tapped the Mac, heard the Crowd clip play. Session 4 audio path is real, not just test-passing.

**Outstanding hardware feedback from that test:** the default `gForceThreshold: 1.5` is too high. Natural / comfortable taps don't fire; only firm slams do. **Lower the default** on the next calibration pass. See cheat audit item #5.

## 3. Resume command (from repo root)

```sh
cd /Users/claude/Desktop/dev/yellback-core   # or wherever the user has the main checkout
git pull
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # confirm 135/135 green
sudo swift run yellback --config config.example.yaml --listen          # tap your Mac, listen for the clip
```

## 4. Workflow conventions (established Sessions 1–4)

These are habits to follow unless the user explicitly says otherwise. Mirrored in `PROGRESS.md` § "Workflow Conventions".

- **No feature branches.** Work on a worktree branch `claude/<name>`, but at session end fast-forward `main` and push directly. User: _"I am not a big fan of branches. I always want to go back to main as soon as possible."_
- **Commit messages via HEREDOC**, with a one-line summary, blank line, body explaining _why_, trailing `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. Match `git log` style.
- **3–5 commits per session** is the loose target. Single big commits OK for small sessions; break into logical pieces (types → impl → tests → docs) for larger work.
- **Don't commit unless asked.** Session-end commits are implicitly authorized once the user starts the session per PROGRESS.md's Next Session block.
- **Session-start protocol:**
  1. Read `CLAUDE.md` (system reminder usually loads it).
  2. Read `PROGRESS.md` in full.
  3. Read session-specific docs (e.g. `AUDIO_NOTES.md`, `ARCHITECTURE.md`, `CONFIG_SCHEMA.md`).
  4. Run `swift build` and `swift test`. Confirm green.
  5. Restate scope and design choices. Ask clarifying questions until 95% sure of intent.
  6. THEN code.
- **Session-end protocol:**
  1. `swift build` and `swift test` green.
  2. Update `PROGRESS.md`: bump Session count, refresh test count + breakdown, summarise outcome, log architectural decisions, add Session History entry, refresh "Next Session".
  3. Update `SESSION_HANDOFF.md` if the next-session pointer or known-issues priority shifted.
  4. Commit + fast-forward `main` + push.
- **Testing bar (Session 2.5 standard):** boundary values for every closed-interval rule (accept at boundary AND reject just outside); exact source-line accuracy for user-facing diagnostics; `contains()`-style format tests; one drift/sync test per public surface.
- **Cheat audits.** When the user asks "where did you cheat?", give a ranked honest list. Don't minimise. The audits across Sessions 2.5, 3+7, and post-Session-3 fixed real bugs — don't skip them.
- **`DEVELOPER_DIR`** prefix required for `swift test` on this machine (Command Line Tools doesn't have XCTest; full Xcode does). Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unconditionally.

## 5. Known Issues (priorities by impact)

Full list in `PROGRESS.md` § "Known Issues". The ones that bite when changing audio code:

1. **Device-change handler not implemented** (`SoundEngine`). Headphone plug/unplug or output switch via Control Center silently breaks playback until restart. `AUDIO_NOTES.md` documents the full handler (stop engine → disconnect all nodes → reconnect at new format → restart). Deferred to **Session 4b**. The "#1 source of production bugs in AVAudioEngine apps" per AUDIO_NOTES.md, so don't ship YellBack-mac without it.
2. **System-mute detection not implemented.** `outputNode.outputVolume` (cited in AUDIO_NOTES.md) doesn't exist on `AVAudioOutputNode` on macOS — the doc was iOS-shaped. Real detection requires CoreAudio (`kAudioDevicePropertyMute` on the default output device). Engine plays even when system is muted. Deferred to **Session 4b**.
3. **Bundle.module pack resolution not done.** CLI finds `Resources/Packs/crowd/` via `cwd`-relative path. Works when run via `swift run yellback ...` from the repo root; breaks for distributed binaries. Deferred until packaging-for-distribution is on the roadmap.
4. **SPU sensor wake step is undocumented Apple API.** Property keys `SensorPropertyReportingState`, `SensorPropertyPowerState`, `ReportInterval` and the `AppleSPUHIDDriver` service class name are reverse-engineered. Apple could rename in any macOS update. Local drift tests catch in-repo edits; nothing catches Apple-side renames. **Verify manually on each major macOS upgrade before shipping.**
5. **Desk-bang requires `sudo`.** `IOHIDManagerOpen` returns `kIOReturnNotPrivileged` to non-root processes. No public entitlement grants this access. Paid Mac app will need an `SMAppService.daemon`-style privileged helper.
6. **CLI binary unsigned, no Info.plist.** Mic TCC routes through Terminal's grant rather than per-app dialog. Fine for OSS dev path; binary is not distributable as a standalone executable for end users.
7. **`parseReport` tests have residual circularity.** Both parser and fixture-builder use the same documented Q16.16 wire format. Local refactors to wrong offsets fail (the bytes there are zero or noise), but a future Apple Silicon chip with a different layout would have parser AND tests wrong together.
8. **Desk-bang threshold and intensity scale uncalibrated.** `gForceThreshold: 1.5` came from research, not measurements. Could be over-sensitive or under-sensitive. Needs an empirical calibration session before YellBack-mac ships.
9. **`swift test` requires full Xcode.** Workaround: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Not a code bug; macOS SwiftPM caveat.

## 6. Possible next sessions (rough priority order)

| Option | Scope | Effort |
|---|---|---|
| **Calibration spike (recommended first)** | Empirical tuning of `gForceThreshold` + intensity scale against actual M-series readings. User has already reported 1.5g feels too high on M2. Add debug logging that prints raw g-force during taps; user runs `--listen` and taps at varying intensities; pick a sensible default. | 30 min |
| **Session 4b** | Close the three deferred AUDIO_NOTES items: device-change handler, system-mute via CoreAudio, `Bundle.module` pack resolution | 1–2 hours |
| **Session 5** | `YellBackEngine` public API + `PrimingState` + engine-level cooldown filtering + `SessionStats`. Replaces CLI's direct detector→soundEngine wiring with the public engine. Detectors' `primingMultiplier` hooks (Session 3 addendum) are already in place — Session 5 wires them. | One full session |
| **Session 6** | `KeyboardDetector` (CGEventTap, Accessibility permission, conforms to existing `Detector` protocol). | One session |
| **Session 12 (much later)** | Source real CC0/CC-BY audio for the Crowd pack. Replaces synthesised placeholders. Content work, not engineering. | Half session |

## 7. Things to NOT do (footguns)

- **Don't propose "fixing" the sudo requirement** for desk-bang without engaging with the IOKit research summary in `PROGRESS.md`. The privilege requirement is real (`IOHIDManagerOpen` returns `kIOReturnNotPrivileged`); no entitlement bypasses it. Any attempt to "make sudo unnecessary" without explicit user request is wasted work.
- **Don't add `kIOHIDOptionsTypeSeizeDevice`** to `AccelerometerDetector`. Tried in Session 3+7 (commit `7dcec43`). It evicts other SPU consumers (notably the OS lid-angle service) that keep the sensor woken on M2/M3/M4. Sensor goes silent. If you find yourself wanting "exclusive HID access" — read the wake-step rationale instead.
- **Don't add explicit per-device `IOHIDDeviceOpen` / `IOHIDDeviceScheduleWithRunLoop`** after the manager-level open. Was harmless on M1 but broke M3+ delivery. Manager-level open already covers matched devices.
- **Don't use `CMMotionManager`.** It's `API_UNAVAILABLE(macos)` for the entire `CM*Manager` family. Confirmed via SDK headers in Session 3+7. The IOKit HID + SPU wake path is the only public route on macOS.
- **Don't use `load(fromByteOffset:as:)` on raw HID reports.** Offsets 6/10/14 aren't 4-byte-aligned; `.load` traps on unaligned reads. Use `.loadUnaligned(fromByteOffset:as:)`.
- **Don't add cooldown logic to detectors.** Was on `MicDetector` initially, removed in Session 3+7. Cooldown is engine-level, will be wired in Session 5. Detectors emit at their natural cadence; engine filters rapid-fire events before audio playback.
- **Don't allocate `AVAudioPlayerNode`s at trigger time** in `SoundEngine`. The 8-node pool is pre-connected to the mixer at `init()`. Allocation + connection takes 10–50ms and blows the 100ms latency budget. If all 8 are busy, drop the trigger silently.
- **Don't load clips lazily** ("we'll decode it when we need it"). Disk I/O at trigger time is the latency budget's mortal enemy. `PackLoader.load(...)` decodes everything up-front into `AVAudioPCMBuffer`s matching the engine's format.
- **Don't reinstantiate `AVAudioEngine` on config change.** Multi-second startup cost. Keep the engine alive for the process lifetime; reconfigure in place.
- **Don't squash the three `WIP:` commits** (`1c411bb`, `7dcec43`, `3225fcd`) on main. User explicitly preferred honest history. The commits document the IOKit-debugging story.

## 8. Glossary

- **`Trigger` (enum)** — `.scream`, `.rageType`, `.deskBang`. The three event types detectors can emit. `Trigger.snakeCaseName` renders as `scream`/`rage_type`/`desk_bang` matching `CONFIG_SCHEMA.md` and the YAML users edit.
- **`TriggerEvent`** — discrete fire event from a detector: `(trigger, timestamp, intensity, wasPrimed)`. Has a `consoleLogLine` extension for stderr rendering.
- **`IntensitySignal`** — continuous per-buffer signal from a detector: `(value, timestamp)`. Emitted regardless of threshold; in v1 nobody consumes it; in v2 the planned multimodal-fusion module will. Forward-compat — don't remove to "simplify."
- **`Detector` (protocol)** — shared interface every detector conforms to: `trigger`, `isEnabled`, `onTriggerEvent`, `onIntensitySignal`, `start() throws`, `stop()`. No cooldown on the protocol surface — that's engine-level. Defined in `Sources/YellBackCore/Detectors/Detector.swift`.
- **`primingMultiplier`** — engine-settable property on each detector. Lowers the effective threshold during a priming window. The engine sets it when its `PrimingState` transitions; the detector uses it inside `process()` to compute the effective threshold. Default `1.0` (no priming). Session 3 addendum landed the hook; Session 5 will wire it.
- **Tier (low / medium / high)** — clip-selection bucket derived from `intensity`. Thresholds: `0..0.33`, `0.33..0.66`, `0.66..1.0`. Hardcoded per `AUDIO_NOTES.md` — not user-tunable.
- **No-repeat** — per-tier `Set<String>` of recently-played clip filenames. Selection excludes recently-played; on tier exhaustion clear and start over. **Per-tier, not global.**
- **Crowd pack** — bundled default sound pack at `Resources/Packs/crowd/`. Currently 6 placeholder clips synthesised by `Scripts/generate_placeholder_clips.swift`. Real CC0/CC-BY clips come in Session 12.
- **SPU** — Apple Silicon's "Sensor Processing Unit." Houses the BMI286 accelerometer that desk-bang reads. M1 base / Mac mini / Mac Studio / Mac Pro lack it (or expose nothing). M1 Pro/Max/Ultra and all M2/M3/M4 have it.

## 9. Hardware / environment expectations

- **Architecture:** Apple Silicon Mac required. Intel Macs lack `AppleSPUHIDDevice` access; they'd need a separate IOKit pathway through the older Sudden Motion Sensor that we haven't implemented.
- **macOS:** 14+ per `Package.swift` `platforms: [.macOS(.v14)]`. Verified through 15.x.
- **Privilege:** Run `--listen` with `sudo` for desk-bang. Without sudo, `AccelerometerDetector.start()` throws `.needsPrivilegedAccess` and is skipped; scream still works.
- **Microphone permission:** First `--listen` run prompts via Terminal's TCC. Granted once, applies to anything Terminal launches.
- **Xcode:** Full Xcode required for `swift test` (XCTest framework). Command Line Tools alone won't work. Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## 10. Things only in conversation that aren't in repo files

(Captured here so future sessions don't lose them.)

- **The "WIP:" commits on main are intentional honest history.** Don't squash. The user said: _"I am not a big fan of branches. I always want to go back to main as soon as possible."_ The IOKit-debugging story across `1c411bb` → `7dcec43` → `3225fcd` is the canonical example of figuring out the SPU wake step.
- **The user's M2 verified scream working in Session 3+7 final** but had stale code at first because I hadn't pushed. **Always push before asking the user to test.** I learned this the hard way mid-Session-3+7 when I told them to re-run a fix that was sitting uncommitted in the worktree.
- **The `git remote -v` output exposes a PAT.** This was visible in this conversation's tool output. Worth rotating at maintenance time.
- **The audio output (Session 4) has not been heard by the user yet.** Tests pass; engineering says it should work; nothing has been auditioned. _The single most important next-session step is the user running `--listen` and confirming by ear._
- **`AVAudioEngine.start()` hangs in non-interactive sandbox environments** when TCC is `.notDetermined`. We added a 2-second timeout via `MicDetector.requestMicrophoneAccess(timeout:requestImpl:)` to fail fast in those contexts. On a real Mac with interactive Terminal, TCC prompts and the user grants — works as expected.
- **Three `WIP:` commits** correspond to three rounds of IOKit debugging:
  - `1c411bb` — switch from manager-level to per-device callback (didn't fix it)
  - `7dcec43` — try `kIOHIDOptionsTypeSeizeDevice` (made it WORSE on M2 by evicting the OS lid-angle consumer)
  - `3225fcd` — drop seize, drop double-open, walk IORegistry for `AppleSPUHIDDriver` and write the wake properties (the actual fix)
- **The user is moving to the CLI version of Claude Code** to install plugin-marketplace tooling that enables multi-agent automation. Same project (`yellback-core`); they're switching environments because `/plugin marketplace add` isn't available in the current Claude Code environment. After installing the tooling, work continues on `yellback-core` from the post-Session-4 state.
- **The user works on a Mac at `/Users/claude/Desktop/dev/yellback-core/`.** Worktrees live under `.claude/worktrees/`. Don't assume any other path.

## 11. Session History at a glance

Full detail in `PROGRESS.md` § "Session History". Quick scan:

| # | Date | Scope | Tests | Commits |
|---|---|---|---|---|
| 1 | 2026-04-24 | Bootstrap Swift Package scaffold | 1 | `2fb5beb` |
| 2 | 2026-04-24 | `ConfigLoader` + typed `EngineConfig` | 39 | `5a52bd6` → `0b11f95` → `65d49db` |
| 2 addendum | 2026-04-24 | Move validation onto leaf struct inits (per user review) | 39 | `0ad4184` |
| 2.5 | 2026-04-24 | Test-thoroughness pass (boundary, diagnostics, drift). Caught + fixed off-by-one in error description rendering. | 57 | `1997e2a` |
| 3 | 2026-04-25 | `MicDetector` + synthetic-audio tests | 73 | `f8c6527` → `4663eed` → `2d63793` |
| 3 addendum | 2026-04-25 | Detector consults priming state per `ARCHITECTURE.md` line 33 | 75 | `de70288` |
| 3+7 combo | 2026-04-25 | `Detector` protocol + `MicDetector` refactor + `AccelerometerDetector` + `--listen` CLI. Discovered `CMMotionManager` is `API_UNAVAILABLE(macos)`; pivoted to IOKit HID. | 94 | `962afcc` → `49ee41b` → `ba6a3e3` |
| 3+7 final | 2026-04-26 | Get desk-bang firing on M2. Three WIP iterations to find the SPU wake step. | 94 | `1c411bb` → `7dcec43` → `3225fcd` → `9e8e3d6` |
| Cheat audit batch 1 | 2026-04-26 | Land 4 audit fixes (`Trigger.snakeCaseName`, accelerometer privacy invariant, SPU wake drift tests, IOKit error refactor) | 102 | `f8a2dad` |
| Cheat audit batch 2 | 2026-04-26 | Land 3 more audit fixes (mic permission timeout, `TriggerEvent.consoleLogLine`, parseReport wire-format tests) | 115 | `cff3dc6` |
| Known Issues doc | 2026-04-26 | Document 5 surfaced footguns | 115 | `67cd9ad` |
| 4 | 2026-04-26 | `SoundEngine` + `SoundPack` + `PackLoader` + bundled Crowd placeholder pack + CLI wiring | 135 | `e07f4d8` → `c9d06ea` |

## 12. If you're an agent picking this up cold

1. **Read this file end-to-end** before doing anything.
2. **Read `CLAUDE.md` and `PROGRESS.md`.**
3. **Read session-specific docs** based on what the user wants:
   - Audio work → `AUDIO_NOTES.md`
   - Engine wiring → `ARCHITECTURE.md`
   - Config work → `CONFIG_SCHEMA.md`
4. **Run `swift test` to confirm 135 green.** If anything fails, fix that before any new work.
5. **Don't push anything to `main` without an explicit user instruction or a session-end summary.**
6. **Match the prose style of existing PROGRESS.md decision log entries** — declarative, dated, rationale-forward, "[session N / YYYY-MM-DD]" prefix.
7. **The user values honest gap-naming** over heroic claims. When you "cheat" (skip a test, defer a hard problem, take a shortcut), document it.
8. **Check this file's "Things to NOT do" section before any IOKit or AVAudioEngine work.** Each entry there cost real iteration to learn.
