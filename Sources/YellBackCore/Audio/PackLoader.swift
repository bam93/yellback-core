import Foundation
import AVFoundation
import Yams

/// Errors thrown by `PackLoader` when a pack directory can't be turned into
/// a valid, fully-loaded `SoundPack`.
public enum PackError: Error, CustomStringConvertible {
    /// `pack.yaml` is missing, unreadable, or syntactically malformed.
    case malformedManifest(path: String, reason: String)

    /// Required field missing in `pack.yaml` (e.g. `id`, `tiers`).
    case missingField(field: String, path: String)

    /// One or more tiers are absent from `pack.yaml` or have an empty clip list.
    case emptyTier(tier: Tier, path: String)

    /// A clip filename listed in `pack.yaml` doesn't exist or can't be read
    /// from disk.
    case clipFileMissing(filename: String, packPath: String)

    /// A `.caf` (or any audio file) failed to decode into an
    /// `AVAudioPCMBuffer`. Wraps the underlying error for grep-ability.
    case clipDecodeFailed(filename: String, underlying: String)

    /// A clip is longer than the maximum allowed duration.
    case clipTooLong(filename: String, durationSeconds: Double, maxSeconds: Double)

    public var description: String {
        switch self {
        case .malformedManifest(let path, let reason):
            return "malformed pack.yaml at \(path): \(reason)"
        case .missingField(let field, let path):
            return "pack.yaml at \(path) is missing required field `\(field)`"
        case .emptyTier(let tier, let path):
            return "pack.yaml at \(path) has empty or missing `\(tier)` tier; every tier must list >= 1 clip"
        case .clipFileMissing(let filename, let packPath):
            return "clip file `\(filename)` listed in \(packPath)/pack.yaml not found on disk"
        case .clipDecodeFailed(let filename, let underlying):
            return "clip `\(filename)` failed to decode: \(underlying)"
        case .clipTooLong(let filename, let duration, let max):
            return "clip `\(filename)` is \(String(format: "%.2f", duration))s, exceeds the \(max)s maximum"
        }
    }
}

/// Loads a sound pack from a directory containing `pack.yaml` and `.caf`
/// clip files into a fully-decoded, ready-to-play `SoundPack`.
///
/// Per `AUDIO_NOTES.md`'s "Clip Preloading" section, every clip is decoded
/// into an `AVAudioPCMBuffer` matching the engine's output format here, at
/// pack-switch time. `SoundEngine` does zero disk I/O at trigger time —
/// any I/O during a trigger blows the 100ms latency budget.
///
/// The output format is supplied by the caller (typically
/// `engine.outputNode.outputFormat(forBus: 0)`) so loaded buffers are ready
/// for the player nodes' mixer connection without any runtime format
/// conversion.
///
/// Loading is synchronous from the loader's perspective — callers should
/// dispatch this to a background queue if they care about not blocking the
/// main thread (typical for pack switches in the paid Mac app's UI).
public enum PackLoader {

    /// Maximum clip duration. Anything longer is rejected at load time as a
    /// likely user error — sound packs are short reaction clips, not music.
    public static let maxClipDurationSeconds: Double = 5.0

    /// Load `directory/pack.yaml` and decode every clip it lists into a
    /// `SoundPack` whose buffers match the supplied output format.
    public static func load(
        from directory: URL,
        outputFormat: AVAudioFormat
    ) throws -> SoundPack {
        let manifestURL = directory.appendingPathComponent("pack.yaml")

        let yaml: String
        do {
            yaml = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            throw PackError.malformedManifest(
                path: manifestURL.path,
                reason: "could not read file: \(error.localizedDescription)"
            )
        }

        let parsed: ParsedManifest
        do {
            parsed = try ParsedManifest.parse(yaml: yaml)
        } catch let e as PackError {
            // Re-wrap with the actual on-disk path so the error tells the
            // user where the broken pack is.
            switch e {
            case .malformedManifest(_, let reason):
                throw PackError.malformedManifest(path: manifestURL.path, reason: reason)
            case .missingField(let field, _):
                throw PackError.missingField(field: field, path: manifestURL.path)
            case .emptyTier(let tier, _):
                throw PackError.emptyTier(tier: tier, path: manifestURL.path)
            default:
                throw e
            }
        }

        var loadedTiers: [Tier: [LoadedClip]] = [:]
        for tier in Tier.allCases {
            let filenames = parsed.clips(in: tier)
            guard !filenames.isEmpty else {
                throw PackError.emptyTier(tier: tier, path: manifestURL.path)
            }
            loadedTiers[tier] = try filenames.map { filename in
                try loadClip(named: filename, from: directory, outputFormat: outputFormat)
            }
        }

        return SoundPack(id: parsed.id, name: parsed.name, tiers: loadedTiers)
    }

    /// Decode one clip from `directory/filename` into an `AVAudioPCMBuffer`
    /// matching `outputFormat`. Pure file-I/O; no engine state involved.
    private static func loadClip(
        named filename: String,
        from directory: URL,
        outputFormat: AVAudioFormat
    ) throws -> LoadedClip {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PackError.clipFileMissing(filename: filename, packPath: directory.path)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PackError.clipDecodeFailed(
                filename: filename,
                underlying: error.localizedDescription
            )
        }

        // Reject overlong clips at load time — pack-build mistakes shouldn't
        // become trigger-time memory/latency hits.
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration <= maxClipDurationSeconds else {
            throw PackError.clipTooLong(
                filename: filename,
                durationSeconds: duration,
                maxSeconds: maxClipDurationSeconds
            )
        }

        // Read at the file's native processing format first, then convert
        // to the engine's output format. Doing the conversion at load time
        // means trigger-time playback uses a buffer the player node can
        // consume directly — no resampling on the audio thread.
        let nativeBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )
        guard let nativeBuffer = nativeBuffer else {
            throw PackError.clipDecodeFailed(
                filename: filename,
                underlying: "could not allocate native PCM buffer"
            )
        }
        do {
            try file.read(into: nativeBuffer)
        } catch {
            throw PackError.clipDecodeFailed(
                filename: filename,
                underlying: "AVAudioFile.read failed: \(error.localizedDescription)"
            )
        }

        let outputBuffer = try convert(
            nativeBuffer,
            to: outputFormat,
            filename: filename
        )
        return LoadedClip(id: filename, buffer: outputBuffer)
    }

    /// Convert `source` into a buffer matching `target` format. Skips the
    /// conversion if the formats already match (saves an allocation +
    /// AVAudioConverter setup for clips that happen to ship at the engine's
    /// native rate).
    private static func convert(
        _ source: AVAudioPCMBuffer,
        to target: AVAudioFormat,
        filename: String
    ) throws -> AVAudioPCMBuffer {
        if source.format == target {
            return source
        }
        guard let converter = AVAudioConverter(from: source.format, to: target) else {
            throw PackError.clipDecodeFailed(
                filename: filename,
                underlying: "could not build converter from \(source.format) to \(target)"
            )
        }

        // Worst-case capacity: ratio of sample rates × source frames + 1024
        // for any small format-conversion overshoot.
        let ratio = target.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: capacity
        ) else {
            throw PackError.clipDecodeFailed(
                filename: filename,
                underlying: "could not allocate output PCM buffer"
            )
        }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        let convertStatus = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if convertStatus == .error || error != nil {
            throw PackError.clipDecodeFailed(
                filename: filename,
                underlying: error?.localizedDescription ?? "AVAudioConverter returned .error"
            )
        }
        return outputBuffer
    }

    // MARK: - Manifest parsing (testable, pure)

    /// Result of parsing `pack.yaml`. Pure value type — no audio buffers,
    /// no I/O. Tests build these directly to exercise schema-validation
    /// branches without hitting the disk.
    internal struct ParsedManifest: Equatable {
        let id: String
        let name: String
        let tiersByName: [String: [String]]

        func clips(in tier: Tier) -> [String] {
            tiersByName[Self.key(for: tier)] ?? []
        }

        private static func key(for tier: Tier) -> String {
            switch tier {
            case .low:    return "low"
            case .medium: return "medium"
            case .high:   return "high"
            }
        }

        /// Parse the YAML body of a pack manifest. Throws `PackError` —
        /// path is filled in with a placeholder; the caller wraps in the
        /// real on-disk path.
        static func parse(yaml: String) throws -> ParsedManifest {
            let raw: Any?
            do {
                raw = try Yams.load(yaml: yaml)
            } catch {
                throw PackError.malformedManifest(path: "<pack.yaml>", reason: error.localizedDescription)
            }
            guard let dict = raw as? [String: Any] else {
                throw PackError.malformedManifest(path: "<pack.yaml>", reason: "top-level YAML must be a mapping")
            }
            guard let id = dict["id"] as? String, !id.isEmpty else {
                throw PackError.missingField(field: "id", path: "<pack.yaml>")
            }
            let name = (dict["name"] as? String) ?? id
            guard let tiersDict = dict["tiers"] as? [String: Any] else {
                throw PackError.missingField(field: "tiers", path: "<pack.yaml>")
            }

            var byName: [String: [String]] = [:]
            for tier in Tier.allCases {
                let tierKey = Self.key(for: tier)
                guard let raw = tiersDict[tierKey] else {
                    throw PackError.emptyTier(tier: tier, path: "<pack.yaml>")
                }
                guard let list = raw as? [String], !list.isEmpty else {
                    throw PackError.emptyTier(tier: tier, path: "<pack.yaml>")
                }
                byName[tierKey] = list
            }
            return ParsedManifest(id: id, name: name, tiersByName: byName)
        }
    }
}
