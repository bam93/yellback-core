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

// MARK: - Trigger rendering

/// Render a `Trigger` in the snake_case vocabulary of CONFIG_SCHEMA.md /
/// config.example.yaml. Matches what users see in their editor.
func snakeCaseName(for trigger: Trigger) -> String {
    switch trigger {
    case .scream: return "scream"
    case .rageType: return "rage_type"
    case .deskBang: return "desk_bang"
    }
}

/// Human-readable per-trigger line. Derives the detector-specific unit
/// (dBFS or g-force) from the `intensity` scalar using the inverse of the
/// linear intensity mapping each detector applies. These are approximate —
/// the underlying detectors don't currently surface the raw measurement.
func formatTriggerLine(_ event: TriggerEvent) -> String {
    let name = snakeCaseName(for: event.trigger).padding(toLength: 10, withPad: " ", startingAt: 0)
    let detail: String
    switch event.trigger {
    case .scream:
        let dbfs = event.intensity * 60 - 60
        detail = String(format: "dbfs=%.2f", dbfs)
    case .deskBang:
        let gForce = event.intensity * 3 + 1
        detail = String(format: "g_force=%.2f", gForce)
    case .rageType:
        detail = "keystrokes=?"
    }
    let primedMark = event.wasPrimed ? " (primed)" : ""
    return String(
        format: "[trigger] %@ intensity=%.2f  %@%@",
        name, event.intensity, detail, primedMark
    )
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

/// Build the set of detectors to start, in declaration order. Disabled
/// detectors get a heads-up line and then aren't instantiated.
var detectors: [Detector] = []

if config.triggers.scream.enabled {
    let d = MicDetector(config: config.triggers.scream)
    d.onTriggerEvent = { event in writeStderr(formatTriggerLine(event)) }
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
    d.onTriggerEvent = { event in writeStderr(formatTriggerLine(event)) }
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
    let name = snakeCaseName(for: d.trigger)
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
    writeStderr("done.")
    exit(0)
}
sigintSource.resume()

// AVAudioEngine's tap callbacks arrive on their own thread; IOHIDManager
// callbacks arrive on the main run loop (scheduled inside the detector).
// Run the main loop so IOKit events get delivered.
RunLoop.main.run()
