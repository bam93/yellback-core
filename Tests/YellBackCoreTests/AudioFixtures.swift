import Foundation
import AVFoundation

/// Synthetic `AVAudioPCMBuffer` generators for detector tests. No committed
/// audio files — every fixture is generated deterministically at test time.
///
/// Each generator returns a mono Float32 buffer at the requested sample rate
/// (44.1kHz by default, matching `MicDetector`'s default). Durations are
/// specified in milliseconds so tests read naturally — "a 350ms sustained
/// tone" rather than "a 15435-frame buffer."
enum AudioFixtures {
    static let defaultSampleRate: Double = 44_100

    /// All-zero samples for the requested duration.
    static func silence(
        durationMs: Int,
        sampleRate: Double = defaultSampleRate
    ) -> AVAudioPCMBuffer {
        let frames = framesFor(durationMs: durationMs, sampleRate: sampleRate)
        return pcmBuffer(frameCount: frames, sampleRate: sampleRate) { _ in 0 }
    }

    /// Pure sine wave at `frequency` Hz, with peak amplitude `amplitude` in
    /// [0, 1]. The RMS of such a buffer is `amplitude / √2`, so dBFS is
    /// predictable: `20·log10(amplitude / √2)`.
    static func sine(
        frequency: Double,
        amplitude: Float,
        durationMs: Int,
        sampleRate: Double = defaultSampleRate
    ) -> AVAudioPCMBuffer {
        let frames = framesFor(durationMs: durationMs, sampleRate: sampleRate)
        let twoPi = 2.0 * .pi
        return pcmBuffer(frameCount: frames, sampleRate: sampleRate) { i in
            Float(Double(amplitude) * sin(twoPi * frequency * Double(i) / sampleRate))
        }
    }

    /// Uniform noise in [-amplitude, +amplitude]. Deterministic given `seed`
    /// so CI failures are reproducible.
    static func whiteNoise(
        amplitude: Float,
        durationMs: Int,
        sampleRate: Double = defaultSampleRate,
        seed: UInt64 = 0xA4F1_BEEF
    ) -> AVAudioPCMBuffer {
        let frames = framesFor(durationMs: durationMs, sampleRate: sampleRate)
        var rng = SplitMix64(seed: seed)
        return pcmBuffer(frameCount: frames, sampleRate: sampleRate) { _ in
            let u = Double(rng.next()) / Double(UInt64.max)
            return Float((u * 2.0 - 1.0) * Double(amplitude))
        }
    }

    /// Concatenate several buffers into one. All buffers must share the same
    /// format. Used to build scenarios like "200ms loud + 200ms silent +
    /// 200ms loud" for testing sustain reset.
    static func concat(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer {
        precondition(!buffers.isEmpty, "concat() requires at least one buffer")
        let format = buffers[0].format
        for b in buffers where b.format != format {
            preconditionFailure("concat() requires all buffers to share a format")
        }
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!
        out.frameLength = AVAudioFrameCount(totalFrames)
        let dst = out.floatChannelData![0]
        var offset = 0
        for b in buffers {
            let n = Int(b.frameLength)
            let src = b.floatChannelData![0]
            for i in 0..<n {
                dst[offset + i] = src[i]
            }
            offset += n
        }
        return out
    }

    /// Split a buffer into consecutive chunks of `chunkMs` milliseconds. The
    /// final chunk may be shorter if the buffer doesn't divide evenly. Tests
    /// use this to feed `MicDetector` in realistic ~23ms slices rather than
    /// one giant buffer.
    static func chunk(
        _ buffer: AVAudioPCMBuffer,
        intoChunksOfMs chunkMs: Int
    ) -> [AVAudioPCMBuffer] {
        let sampleRate = buffer.format.sampleRate
        let framesPerChunk = framesFor(durationMs: chunkMs, sampleRate: sampleRate)
        let totalFrames = Int(buffer.frameLength)
        let src = buffer.floatChannelData![0]

        var out: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < totalFrames {
            let n = min(framesPerChunk, totalFrames - offset)
            let slice = pcmBuffer(frameCount: n, sampleRate: sampleRate) { i in
                src[offset + i]
            }
            out.append(slice)
            offset += n
        }
        return out
    }

    // MARK: - Internals

    private static func framesFor(durationMs: Int, sampleRate: Double) -> Int {
        Int(Double(durationMs) / 1000.0 * sampleRate)
    }

    private static func pcmBuffer(
        frameCount: Int,
        sampleRate: Double,
        sampleAt: (Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let data = buffer.floatChannelData![0]
        for i in 0..<frameCount {
            data[i] = sampleAt(i)
        }
        return buffer
    }
}

/// Deterministic PRNG for reproducible noise fixtures. Public-domain
/// algorithm (SplitMix64) — one multiplication + one shift per sample.
struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}
