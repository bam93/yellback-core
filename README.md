# YellBack Core

The open-source detection engine behind [YellBack](https://yellback.app) — a cathartic companion app that detects physical signs of frustration (screaming, rage-typing, desk-banging) and responds by playing sounds that match your energy.

This is the engine. It runs as a headless CLI daemon and is also consumed by the paid YellBack Mac app, which wraps this engine in a polished menu bar experience with additional sound packs.

## Status

Pre-alpha. Under active development. See [`PROGRESS.md`](./PROGRESS.md) for current state.

## Install & Run

Requires Swift 5.9+ and macOS 14+.

```sh
git clone https://github.com/[owner]/yellback-core
cd yellback-core
swift build -c release
./.build/release/yellback --config config.example.yaml
```

On first run, the CLI will request microphone and accessibility permissions — both are needed for the scream and rage-type detectors respectively. Grant them in System Settings → Privacy & Security.

Once running, the CLI listens for frustration signals and plays sound clips from the bundled Crowd pack. Ctrl-C to stop.

## Configure

Copy `config.example.yaml` to `~/.config/yellback/config.yaml` and edit. The schema is documented in [`CONFIG_SCHEMA.md`](./CONFIG_SCHEMA.md).

## How It Works

Three detectors run in parallel:
- **Scream** detects sustained loud vocal sounds via the microphone
- **Rage type** detects abnormally fast keystroke patterns via system keyboard events
- **Desk bang** detects sharp physical impacts via the MacBook's accelerometer

When any trigger fires, a sound clip plays, volume-matched to the trigger's intensity. Cross-trigger priming makes the detectors more sensitive to each other when the user is already "in the zone."

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the full technical picture.

## Privacy

This app reads microphone input for volume analysis only — audio is never recorded or stored. Keyboard monitoring reads keystroke timing only, never key content. Nothing is transmitted over the network. There are no analytics, no accounts, and no data collection of any kind.

## Contributing

Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) first. Understand the signal/event model and why the core imports no UI frameworks. Then see [`PROGRESS.md`](./PROGRESS.md) for current session scope.

All audio clips in `Resources/Packs/crowd/` must be CC0 or CC-BY compatible. Per-clip licensing is tracked in [`ATTRIBUTIONS.md`](./ATTRIBUTIONS.md).

## License

MIT. See [`LICENSE`](./LICENSE).

## The Paid App

If you want the polished version — onboarding, settings UI, stats dashboard, and two additional sound packs (Destruction and Unhinged Office) — grab [YellBack for Mac](https://yellback.app) for $6.99.
