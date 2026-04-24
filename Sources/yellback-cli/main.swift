import Foundation
import YellBackCore

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage(_ fh: FileHandle) {
    fh.write(Data("usage: yellback --config <path>\n".utf8))
}

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

let rawPath = args[configFlagIndex + 1]
let expanded = (rawPath as NSString).expandingTildeInPath
let configURL = URL(fileURLWithPath: expanded)

do {
    let result = try ConfigLoader.load(from: configURL)

    for warning in result.warnings {
        writeStderr("warning: \(warning)")
    }

    let c = result.config
    print("yellback: loaded config from \(configURL.path)")
    print("  triggers.scream:    enabled=\(c.triggers.scream.enabled)  dbfs_threshold=\(c.triggers.scream.dbfsThreshold)")
    print("  triggers.rage_type: enabled=\(c.triggers.rageType.enabled)  keys/sec=\(c.triggers.rageType.keystrokesPerSecondThreshold)")
    print("  triggers.desk_bang: enabled=\(c.triggers.deskBang.enabled)  g_force=\(c.triggers.deskBang.gForceThreshold)")
    print("  priming:            enabled=\(c.priming.enabled)  window=\(c.priming.windowSeconds)s  mult=\(c.priming.thresholdMultiplier)")
    let volumeStr = c.audio.masterVolume.map { String($0) } ?? "null (follow system)"
    print("  audio:              pack=\(c.audio.pack)  master_volume=\(volumeStr)")
    print("  packs_directory:    \(c.packsDirectory.path)")
    print("  logging.level:      \(c.logging.level.rawValue)")
    print("detectors not yet implemented — exiting.")
} catch let error as ConfigError {
    writeStderr("error: \(error)")
    exit(1)
} catch {
    writeStderr("error: \(error.localizedDescription)")
    exit(1)
}
