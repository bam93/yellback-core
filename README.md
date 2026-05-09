# YellBack Core

The open-source detection engine behind [YellBack](https://yellback.app) — a cathartic companion app that detects physical signs of frustration (screaming, rage-typing, desk-banging) and responds by playing sounds that match your energy.

This is the engine. It runs as a headless CLI daemon and is also consumed by the paid YellBack Mac app, which wraps this engine in a polished menu bar experience with additional sound packs.

## Status

**Pre-alpha.** Two of three detectors work end-to-end; one is not yet implemented. See [`PROGRESS.md`](./PROGRESS.md) for current state and [`SESSION_HANDOFF.md`](./SESSION_HANDOFF.md) for the next-session pointer.

| Feature | Status |
|---|---|
| Scream detection (microphone, RMS + voice band-pass) | ✅ working |
| Desk-bang detection (Apple SPU accelerometer via IOKit HID) | ✅ working — Apple Silicon MacBooks only, requires `sudo` |
| Rage-type detection (CGEventTap on keystroke timing) | ❌ not yet — Session 6 |
| Audio playback via SoundEngine + bundled Crowd pack | ✅ working — placeholder synthesised clips, real CC0 audio comes in Session 12 |
| Cross-trigger priming, engine-level cooldowns | ❌ not yet — Session 5 |
| Public `YellBackEngine` API | ❌ not yet — Session 5 |
| Device-change / system-mute handling in audio output | ❌ not yet — Session 4b ([`PROGRESS.md`](./PROGRESS.md) Known Issues) |

## Install & Run

Requires Swift 5.9+ and macOS 14+ on an Apple Silicon Mac (the desk-bang detector matches on `AppleSPUHIDDevice`, which doesn't exist on Intel Macs or Apple Silicon desktops).

```sh
git clone https://github.com/bam93/yellback-core
cd yellback-core
swift build -c release
```

Two run modes:

```sh
# Print the parsed config, then exit. Useful for verifying YAML before wiring up audio.
./.build/release/yellback --config config.example.yaml

# Listen mode: start enabled detectors, print triggers to stderr, play sounds. Ctrl-C to stop.
sudo ./.build/release/yellback --config config.example.yaml --listen
```

`sudo` is required for `--listen` because the accelerometer detector reads via IOKit HID against `AppleSPUHIDDevice`, which returns `kIOReturnNotPrivileged` to non-root processes. There's no entitlement that grants this access; the eventual paid Mac app handles it via a privileged helper. For dev, just use `sudo`.

On first run the CLI will request microphone permission via the parent Terminal's TCC grant. Grant it; subsequent runs use the cached decision.

## What you should hear

In `--listen` mode, with default config:

- **Scream into the mic for ~300ms** above ~-20 dBFS → stderr: `[trigger] scream     intensity=...  dbfs=...` + an audible clip from the Crowd pack's intensity-matched tier.
- **Tap your Mac firmly** (~1.5g delta from rest) → stderr: `[trigger] desk_bang  intensity=...  g_force=...` + an audible clip.

Tier mapping is `0..0.33` low → `0.33..0.66` medium → `0.66..1.0` high. The bundled Crowd pack has 2 distinguishable placeholder clips per tier.

If you want to see the per-buffer intensity stream, set `logging.level: debug` in the config.

## Configure

Copy `config.example.yaml` to `~/.config/yellback/config.yaml` and edit. The schema is documented in [`CONFIG_SCHEMA.md`](./CONFIG_SCHEMA.md).

## How It Works

Each detector is independent — owns its own thresholds, runs its own input loop, never talks to the other detectors directly. Cross-trigger coordination (priming state, cooldowns) lives on the engine, which is Session 5's deliverable.

When a trigger fires, its `intensity` (0.0–1.0) maps to a tier; the SoundEngine picks a non-recently-played clip from that tier and plays it through one of 8 pre-allocated `AVAudioPlayerNode`s. Volume = `pow(intensity, 0.7)` for perceptual headroom × the user's master volume (or 1.0 = follow system).

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the signal/event duality, the priming state design, and why no UI frameworks are imported. See [`AUDIO_NOTES.md`](./AUDIO_NOTES.md) for AVAudioEngine pitfalls and the player-node-pool reasoning.

## Privacy

This app reads microphone input for level analysis only — audio is never recorded, buffered beyond the analysis window, or stored. Keyboard monitoring (when implemented) will read keystroke _timing_ only, never key content. Accelerometer reads are processed sample-by-sample with no buffering. Nothing is transmitted over the network. There are no analytics, no accounts, and no data collection of any kind.

The "no audio retention" promise is enforced at runtime: `MicDetector` has a `precondition` that fires if it ever caches more than 8 samples (the biquad filter history). `AccelerometerDetector` has the same check at zero retained samples. See `MicDetectorTests.testRetainedAudioSampleCountNeverExceedsEight` and the equivalent for accelerometer.

## Contributing

Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) first. Understand the signal/event model and why the core imports no UI frameworks. Then read [`PROGRESS.md`](./PROGRESS.md) for current session scope and [`SESSION_HANDOFF.md`](./SESSION_HANDOFF.md) for the next-session pointer.

The placeholder clips in `Resources/Packs/crowd/` are synthesised noise + tone bursts (see `Scripts/generate_placeholder_clips.swift`). Real CC0/CC-BY audio replacement is a future content-sourcing session, not engineering. Per-clip licensing for any real audio added later is tracked in [`ATTRIBUTIONS.md`](./ATTRIBUTIONS.md).

Testing bar for new code:
- Boundary values for every closed-interval rule (accept at boundary AND reject just outside)
- Exact source-line accuracy for any user-facing diagnostic
- `contains()`-style format tests for stable-but-not-exact strings
- One drift/sync test per public surface (e.g. config example matches struct defaults; bundled Crowd pack parses cleanly)

## License

MIT. See [`LICENSE`](./LICENSE).

## The Paid App

If you want the polished version — onboarding, settings UI, stats dashboard, cross-trigger priming wired up, and additional sound packs — grab [YellBack for Mac](https://yellback.app) for $6.99 (when shipped).
