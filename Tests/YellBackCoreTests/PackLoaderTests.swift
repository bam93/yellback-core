import XCTest
import AVFoundation
@testable import YellBackCore

/// Unit tests for `PackLoader` and the `ParsedManifest` helper. Tests build
/// synthetic pack directories in a temp dir, write `pack.yaml` + `.caf`
/// files, and load through the real loader. No mocking of file I/O.
final class PackLoaderTests: XCTestCase {

    // MARK: - Helpers

    /// Build a temporary pack directory with the given manifest contents
    /// and a clip per name listed. Each clip is a 100ms mono 44.1kHz tone.
    /// Returns the directory URL (caller's responsibility to leave cleanup
    /// to XCTest's temp-dir lifecycle — not strictly cleaned up between
    /// tests, which is fine since each test creates its own subdir).
    private func makeTempPack(
        yaml: String,
        clipFilenames: [String]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yellback-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try yaml.write(
            to: dir.appendingPathComponent("pack.yaml"),
            atomically: true,
            encoding: .utf8
        )
        for filename in clipFilenames {
            try writeTestClip(named: filename, in: dir, durationMs: 100, frequency: 880)
        }
        return dir
    }

    /// Write a small mono 44.1kHz sine clip into `directory/filename` so
    /// `PackLoader` has a real file to decode.
    private func writeTestClip(
        named filename: String,
        in directory: URL,
        durationMs: Int,
        frequency: Double
    ) throws {
        let sampleRate: Double = 44_100
        let frameCount = AVAudioFrameCount(Double(durationMs) / 1000.0 * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("could not allocate test buffer")
            return
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        let twoPi = 2.0 * .pi
        for i in 0..<Int(frameCount) {
            data[i] = Float(0.3 * sin(twoPi * frequency * Double(i) / sampleRate))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let url = directory.appendingPathComponent(filename)
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private static let standardOutputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Happy path

    func testLoadValidPackProducesAllThreeTiers() throws {
        let yaml = """
        id: test
        name: Test Pack
        tiers:
          low: [a.caf]
          medium: [b.caf, c.caf]
          high: [d.caf]
        """
        let dir = try makeTempPack(yaml: yaml, clipFilenames: ["a.caf", "b.caf", "c.caf", "d.caf"])

        let pack = try PackLoader.load(from: dir, outputFormat: Self.standardOutputFormat)

        XCTAssertEqual(pack.id, "test")
        XCTAssertEqual(pack.name, "Test Pack")
        XCTAssertEqual(pack.clips(in: .low).count, 1)
        XCTAssertEqual(pack.clips(in: .medium).count, 2)
        XCTAssertEqual(pack.clips(in: .high).count, 1)
        XCTAssertEqual(pack.clips(in: .low).first?.id, "a.caf")
    }

    func testLoadConvertsBuffersToOutputFormat() throws {
        // The synthetic clips are mono 44.1kHz Float32. Engine output is
        // stereo 44.1kHz Float32 (per the format constant). The loaded
        // buffer must match the OUTPUT format so the player node can
        // consume it without runtime conversion.
        let yaml = """
        id: t
        name: t
        tiers:
          low: [x.caf]
          medium: [y.caf]
          high: [z.caf]
        """
        let dir = try makeTempPack(yaml: yaml, clipFilenames: ["x.caf", "y.caf", "z.caf"])
        let pack = try PackLoader.load(from: dir, outputFormat: Self.standardOutputFormat)

        let buffer = pack.clips(in: .low).first!.buffer
        XCTAssertEqual(buffer.format.channelCount, 2, "loaded buffer should match the output format's channel count")
        XCTAssertEqual(buffer.format.sampleRate, 44_100, accuracy: 0.01)
        XCTAssertGreaterThan(buffer.frameLength, 0, "buffer should have decoded frames")
    }

    // MARK: - Manifest validation (pure, no I/O)

    func testParseManifestRejectsMissingId() {
        let yaml = """
        name: NoId
        tiers:
          low: [a.caf]
          medium: [b.caf]
          high: [c.caf]
        """
        XCTAssertThrowsError(try PackLoader.ParsedManifest.parse(yaml: yaml)) { error in
            guard case PackError.missingField(let field, _) = error else {
                XCTFail("expected .missingField, got \(error)")
                return
            }
            XCTAssertEqual(field, "id")
        }
    }

    func testParseManifestRejectsMissingTier() {
        let yaml = """
        id: t
        name: t
        tiers:
          low: [a.caf]
          medium: [b.caf]
        """
        XCTAssertThrowsError(try PackLoader.ParsedManifest.parse(yaml: yaml)) { error in
            guard case PackError.emptyTier(let tier, _) = error else {
                XCTFail("expected .emptyTier, got \(error)")
                return
            }
            XCTAssertEqual(tier, .high)
        }
    }

    func testParseManifestRejectsEmptyTierList() {
        let yaml = """
        id: t
        tiers:
          low: []
          medium: [b.caf]
          high: [c.caf]
        """
        XCTAssertThrowsError(try PackLoader.ParsedManifest.parse(yaml: yaml)) { error in
            guard case PackError.emptyTier(let tier, _) = error else {
                XCTFail("expected .emptyTier, got \(error)")
                return
            }
            XCTAssertEqual(tier, .low, "empty list should fail with the same error as a missing tier")
        }
    }

    func testParseManifestDefaultsNameToIdWhenMissing() throws {
        let yaml = """
        id: my_pack
        tiers:
          low: [a.caf]
          medium: [b.caf]
          high: [c.caf]
        """
        let parsed = try PackLoader.ParsedManifest.parse(yaml: yaml)
        XCTAssertEqual(parsed.name, "my_pack", "name should default to id if not specified")
    }

    func testParseManifestRejectsMalformedYAML() {
        let yaml = "id: t\ntiers: { low: [a.caf"  // unterminated
        XCTAssertThrowsError(try PackLoader.ParsedManifest.parse(yaml: yaml)) { error in
            guard case PackError.malformedManifest = error else {
                XCTFail("expected .malformedManifest, got \(error)")
                return
            }
        }
    }

    // MARK: - On-disk validation

    func testLoadFailsWhenClipFileMissing() throws {
        let yaml = """
        id: t
        tiers:
          low: [present.caf]
          medium: [absent.caf]
          high: [present.caf]
        """
        let dir = try makeTempPack(yaml: yaml, clipFilenames: ["present.caf"]) // absent.caf NOT created
        XCTAssertThrowsError(try PackLoader.load(from: dir, outputFormat: Self.standardOutputFormat)) { error in
            guard case PackError.clipFileMissing(let filename, _) = error else {
                XCTFail("expected .clipFileMissing, got \(error)")
                return
            }
            XCTAssertEqual(filename, "absent.caf")
        }
    }

    func testLoadFailsWhenManifestAbsent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yellback-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No pack.yaml at all.
        XCTAssertThrowsError(try PackLoader.load(from: dir, outputFormat: Self.standardOutputFormat)) { error in
            guard case PackError.malformedManifest = error else {
                XCTFail("expected .malformedManifest, got \(error)")
                return
            }
        }
    }

    // MARK: - Bundled-pack drift

    /// Catches the equivalent of `config.example.yaml`-vs-defaults drift
    /// from Session 2.5: the bundled Crowd pack at `Resources/Packs/crowd/`
    /// must always parse cleanly. If anyone breaks `pack.yaml` or removes
    /// a clip referenced by it, this test fails.
    func testBundledCrowdPackParsesCleanly() throws {
        // Path: this file is at Tests/YellBackCoreTests/PackLoaderTests.swift
        // The repo root is two `..` away.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/YellBackCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let crowdDir = repoRoot.appendingPathComponent("Resources/Packs/crowd")

        let pack = try PackLoader.load(from: crowdDir, outputFormat: Self.standardOutputFormat)
        XCTAssertEqual(pack.id, "crowd")
        XCTAssertFalse(pack.clips(in: .low).isEmpty)
        XCTAssertFalse(pack.clips(in: .medium).isEmpty)
        XCTAssertFalse(pack.clips(in: .high).isEmpty)
    }
}
