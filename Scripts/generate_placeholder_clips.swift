#!/usr/bin/env swift
// generate_placeholder_clips.swift
//
// Builds the 6 placeholder .caf clips for the Crowd pack into
// Resources/Packs/crowd/. Each clip is a short distinguishable noise so
// you can audibly verify tier selection during manual --listen testing.
// They are NOT meant to sound like real audience reactions — Session 12
// will replace them with sourced CC0/CC-BY audio.
//
// Run from the repo root:
//   swift Scripts/generate_placeholder_clips.swift
//
// Output (overwrites if present):
//   Resources/Packs/crowd/clap_short_a.caf       (low tier)
//   Resources/Packs/crowd/clap_short_b.caf       (low tier)
//   Resources/Packs/crowd/cheer_mid_a.caf        (medium tier)
//   Resources/Packs/crowd/cheer_mid_b.caf        (medium tier)
//   Resources/Packs/crowd/roar_long_a.caf        (high tier)
//   Resources/Packs/crowd/roar_long_b.caf        (high tier)
//
// Each clip is mono 44.1 kHz Float32 with a different fundamental
// frequency, duration, and envelope so they're trivially distinguishable
// when played back through the SoundEngine.

import Foundation
import AVFoundation

let sampleRate: Double = 44_100
let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Packs/crowd", isDirectory: true)

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct ClipSpec {
    let filename: String
    let durationMs: Int
    let frequency: Double      // base tone (Hz)
    let noiseRatio: Double     // 0.0 = pure tone, 1.0 = pure noise; mix of tone + filtered noise
    let attackMs: Int          // milliseconds to ramp up
    let decayMs: Int           // milliseconds to ramp down at the end
}

let specs: [ClipSpec] = [
    // Low tier — short, high-frequency, sharp envelope (clap-like).
    ClipSpec(filename: "clap_short_a.caf", durationMs: 180, frequency: 2200, noiseRatio: 0.7, attackMs: 5, decayMs: 60),
    ClipSpec(filename: "clap_short_b.caf", durationMs: 200, frequency: 2600, noiseRatio: 0.7, attackMs: 5, decayMs: 70),
    // Medium tier — medium duration, mid-frequency (cheer-like).
    ClipSpec(filename: "cheer_mid_a.caf", durationMs: 450, frequency: 800, noiseRatio: 0.4, attackMs: 30, decayMs: 150),
    ClipSpec(filename: "cheer_mid_b.caf", durationMs: 500, frequency: 700, noiseRatio: 0.5, attackMs: 30, decayMs: 180),
    // High tier — long, low-frequency, broad envelope (roar-like).
    ClipSpec(filename: "roar_long_a.caf", durationMs: 800, frequency: 200, noiseRatio: 0.6, attackMs: 80, decayMs: 250),
    ClipSpec(filename: "roar_long_b.caf", durationMs: 850, frequency: 250, noiseRatio: 0.7, attackMs: 80, decayMs: 280),
]

func synthesize(spec: ClipSpec) -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(Double(spec.durationMs) / 1000.0 * sampleRate)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: 1,
                                     interleaved: false) else {
        fatalError("could not build mono Float32 format at \(sampleRate) Hz")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        fatalError("could not allocate buffer for \(spec.filename)")
    }
    buffer.frameLength = frameCount
    let data = buffer.floatChannelData![0]

    let twoPi = 2.0 * Double.pi
    let attackFrames = max(1, Int(Double(spec.attackMs) / 1000.0 * sampleRate))
    let decayFrames = max(1, Int(Double(spec.decayMs) / 1000.0 * sampleRate))
    let total = Int(frameCount)
    let decayStart = max(0, total - decayFrames)

    var seed: UInt64 = UInt64(bitPattern: Int64(spec.filename.hashValue))
    func rng() -> Double {
        // SplitMix64
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z &>> 31)
        return Double(z) / Double(UInt64.max) * 2.0 - 1.0
    }

    for i in 0..<total {
        let t = Double(i) / sampleRate
        let tone = sin(twoPi * spec.frequency * t)
        let noise = rng()
        var sample = (1.0 - spec.noiseRatio) * tone + spec.noiseRatio * noise

        // Envelope: linear attack, plateau, linear decay.
        var envelope: Double = 1.0
        if i < attackFrames {
            envelope = Double(i) / Double(attackFrames)
        } else if i >= decayStart {
            envelope = max(0.0, 1.0 - Double(i - decayStart) / Double(decayFrames))
        }
        sample *= envelope * 0.6  // headroom; avoids clipping during mixer summation

        data[i] = Float(sample)
    }
    return buffer
}

func write(buffer: AVAudioPCMBuffer, to url: URL) throws {
    let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: true,
    ]
    let file = try AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

for spec in specs {
    let buffer = synthesize(spec: spec)
    let url = outDir.appendingPathComponent(spec.filename)
    do {
        try write(buffer: buffer, to: url)
        print("wrote \(spec.filename) — \(spec.durationMs)ms @ \(Int(spec.frequency))Hz, noise=\(String(format: "%.0f", spec.noiseRatio * 100))%")
    } catch {
        print("ERROR writing \(spec.filename): \(error.localizedDescription)")
        exit(1)
    }
}

print("done. \(specs.count) placeholder clips in \(outDir.path)")
