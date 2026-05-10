import Foundation
import YellBackCore

// MARK: - Small utilities

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage(_ fh: FileHandle) {
    fh.write(Data("""
    usage: yellback --config <path> [--listen] [--help]

      --config <path>   Load config from YAML file (required).
      --listen          After loading config, start enabled detectors
                        and stream triggers to stderr. Ctrl-C stops.
      --help, -h        Print this message and exit.

    Note: `--listen` with desk_bang enabled requires root (sudo) to
    access the Apple SPU accelerometer. Without root, desk_bang is
    skipped with a warning; other detectors continue normally.

    """.utf8))
}

// MARK: - Argument parsing

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    printUsage(.standardOutput)
    exit(0)
}

guard let configFlagIndex = args.firstIndex(of: "--config"),
      configFlagIndex + 1 < args.count else {
    printUsage(.standardError)
    exit(2)
}

let shouldListen = args.contains("--listen")
let rawPath = args[configFlagIndex + 1]
let expanded = (rawPath as NSString).expandingTildeInPath
let configURL = URL(fileURLWithPath: expanded)

// MARK: - Load config

let loadResult: ConfigLoader.LoadResult
do {
    loadResult = try ConfigLoader.load(from: configURL)
} catch let error as ConfigError {
    writeStderr("error: \(error)")
    exit(1)
} catch {
    writeStderr("error: \(error.localizedDescription)")
    exit(1)
}

for warning in loadResult.warnings {
    writeStderr("warning: \(warning)")
}

let config = loadResult.config

// MARK: - Non-listen path (config summary + exit)

guard shouldListen else {
    print("yellback: loaded config from \(configURL.path)")
    print("  triggers.scream:    enabled=\(config.triggers.scream.enabled)  dbfs_threshold=\(config.triggers.scream.dbfsThreshold)")
    print("  triggers.rage_type: enabled=\(config.triggers.rageType.enabled)  keys/sec=\(config.triggers.rageType.keystrokesPerSecondThreshold)")
    print("  triggers.desk_bang: enabled=\(config.triggers.deskBang.enabled)  g_force=\(config.triggers.deskBang.gForceThreshold)")
    print("  priming:            enabled=\(config.priming.enabled)  window=\(config.priming.windowSeconds)s  mult=\(config.priming.thresholdMultiplier)")
    let volumeStr = config.audio.masterVolume.map { String($0) } ?? "null (follow system)"
    print("  audio:              pack=\(config.audio.pack)  master_volume=\(volumeStr)")
    print("  packs_directory:    \(config.packsDirectory.path)")
    print("  logging.level:      \(config.logging.level.rawValue)")
    print("detectors not started (pass --listen to start them).")
    exit(0)
}

// MARK: - Listen mode

writeStderr("yellback: listening with config \(configURL.path)")

// MARK: - Resolve the bundled-pack dev-mode path
//
// The engine resolves packs against `config.packsDirectory`, which defaults
// to `~/.config/yellback/packs`. When running via `swift run yellback ...`
// from the repo root (the dev workflow), the user expects the bundled
// `./Resources/Packs/crowd/` to "just work" without setting up a user
// pack directory. If the configured pack id maps to a manifest sitting
// next to cwd's `Resources/Packs/`, we override `packsDirectory` to that
// cwd-relative path. Phase 4b will replace this with proper `Bundle.module`
// resolution.

let cwdPacksDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Packs")
let cwdPackManifest = cwdPacksDir
    .appendingPathComponent(config.audio.pack)
    .appendingPathComponent("pack.yaml")

let effectiveConfig: EngineConfig
if FileManager.default.fileExists(atPath: cwdPackManifest.path) {
    effectiveConfig = EngineConfig(
        triggers: config.triggers,
        priming: config.priming,
        audio: config.audio,
        packsDirectory: cwdPacksDir,
        logging: config.logging
    )
    writeStderr("  packs: using cwd-relative dev path \(cwdPacksDir.path)")
} else {
    effectiveConfig = config
}

// MARK: - Build the YellBackEngine
//
// The engine owns SoundEngine setup, pack loading, detector lifecycle,
// PrimingState, cooldown filtering, and SessionStats. The CLI's job is
// only to print stderr lines and route SIGINT to engine.stop().

let engine = YellBackEngine(config: effectiveConfig)

engine.onTrigger = { event in
    writeStderr(event.consoleLogLine)
}

if config.logging.level == .debug {
    engine.onIntensity = { trigger, signal in
        writeStderr(String(
            format: "[intensity] %@ %.3f",
            trigger.snakeCaseName.padding(toLength: 10, withPad: " ", startingAt: 0),
            signal.value
        ))
    }
}

engine.onPermissionStateChange = { state in
    writeStderr("  permissions: mic=\(state.microphone), accessibility=\(state.accessibility)")
}

do {
    try engine.start()
    for warning in engine.startupWarnings {
        writeStderr("  warning: \(warning)")
    }
    let started = engine.startedTriggers.map { $0.snakeCaseName }.joined(separator: ", ")
    writeStderr("  started: [\(started)]")
    writeStderr("listening. Ctrl-C to stop.")
} catch let error as EngineError {
    writeStderr("error: \(error)")
    exit(1)
} catch {
    writeStderr("error: \(error.localizedDescription)")
    exit(1)
}

// MARK: - SIGINT handler + run loop

// Ignore the default SIGINT (which would terminate immediately) and let
// our DispatchSource catch it so we can stop the engine cleanly.
signal(SIGINT, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    writeStderr("")  // newline past any in-progress ^C echo
    writeStderr("stopping engine…")
    engine.stop()
    writeStderr("done.")
    exit(0)
}
sigintSource.resume()

// AVAudioEngine's tap callbacks arrive on their own thread; IOHIDManager
// callbacks arrive on the main run loop (scheduled inside the detector).
// Run the main loop so IOKit events get delivered.
RunLoop.main.run()
