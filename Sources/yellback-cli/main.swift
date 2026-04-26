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

// MARK: - Bring up the audio engine + load the bundled Crowd pack

import AVFoundation

let soundEngine: SoundEngine?
do {
    let engine = try SoundEngine()
    engine.verboseDiagnostics = (config.logging.level == .debug)
    engine.masterVolume = config.audio.masterVolume

    // Load the bundled Crowd pack from the repo's Resources tree. In the
    // dev path (`swift run yellback ...` from the repo root), this is
    // simply `./Resources/Packs/crowd/`. A future packaged release will
    // resolve via `Bundle.module` once Package.swift declares the
    // resources properly — see PROGRESS.md known issue.
    let crowdDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/Packs/crowd")
    if FileManager.default.fileExists(atPath: crowdDir.appendingPathComponent("pack.yaml").path) {
        do {
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 2,
                interleaved: false
            )!
            let pack = try PackLoader.load(from: crowdDir, outputFormat: outputFormat)
            engine.setPack(pack)
            writeStderr("  audio: loaded pack '\(pack.id)' from \(crowdDir.path)")
        } catch {
            writeStderr("  audio: failed to load Crowd pack — \(error). Triggers will fire silently.")
        }
    } else {
        writeStderr("  audio: no bundled Crowd pack at \(crowdDir.path); triggers fire silently. (Run `swift Scripts/generate_placeholder_clips.swift` to make placeholders.)")
    }

    soundEngine = engine
} catch {
    writeStderr("  audio: SoundEngine failed to start — \(error). Triggers will fire silently.")
    soundEngine = nil
}

/// Closure consumed by detector `onTriggerEvent` callbacks: log the event
/// AND drive the audio engine. Captured separately so both detectors get
/// the same wiring without duplicating the body.
let dispatchTrigger: (TriggerEvent) -> Void = { event in
    writeStderr(event.consoleLogLine)
    soundEngine?.play(intensity: event.intensity)
}

/// Build the set of detectors to start, in declaration order. Disabled
/// detectors get a heads-up line and then aren't instantiated.
var detectors: [Detector] = []

if config.triggers.scream.enabled {
    let d = MicDetector(config: config.triggers.scream)
    d.onTriggerEvent = dispatchTrigger
    if config.logging.level == .debug {
        d.onIntensitySignal = { sig in
            writeStderr(String(format: "[intensity] scream     %.3f", sig.value))
        }
    }
    detectors.append(d)
} else {
    writeStderr("  triggers.scream: disabled in config — skipping")
}

if config.triggers.deskBang.enabled {
    let d = AccelerometerDetector(config: config.triggers.deskBang)
    d.verboseDiagnostics = (config.logging.level == .debug)
    d.onTriggerEvent = dispatchTrigger
    if config.logging.level == .debug {
        d.onIntensitySignal = { sig in
            writeStderr(String(format: "[intensity] desk_bang  %.3f", sig.value))
        }
    }
    detectors.append(d)
} else {
    writeStderr("  triggers.desk_bang: disabled in config — skipping")
}

if config.triggers.rageType.enabled {
    writeStderr("  triggers.rage_type: enabled in config but KeyboardDetector not yet implemented — skipping")
}

// MARK: - Start detectors

var startedDetectors: [Detector] = []

for d in detectors {
    let name = d.trigger.snakeCaseName
    do {
        try d.start()
        writeStderr("  triggers.\(name): started")
        startedDetectors.append(d)
    } catch let error as DetectorError {
        writeStderr("  triggers.\(name): NOT started — \(error)")
    } catch {
        writeStderr("  triggers.\(name): NOT started — \(error.localizedDescription)")
    }
}

if startedDetectors.isEmpty {
    writeStderr("no detectors started; exiting.")
    exit(1)
}

writeStderr("listening. Ctrl-C to stop.")

// MARK: - SIGINT handler + run loop

// Ignore the default SIGINT (which would terminate immediately) and let
// our DispatchSource catch it so we can stop detectors cleanly.
signal(SIGINT, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    writeStderr("") // newline past any in-progress ^C echo
    writeStderr("stopping detectors…")
    for d in startedDetectors { d.stop() }
    soundEngine?.stop()
    writeStderr("done.")
    exit(0)
}
sigintSource.resume()

// AVAudioEngine's tap callbacks arrive on their own thread; IOHIDManager
// callbacks arrive on the main run loop (scheduled inside the detector).
// Run the main loop so IOKit events get delivered.
RunLoop.main.run()
