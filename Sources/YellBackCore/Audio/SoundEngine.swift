import Foundation

/// Wraps `AVAudioEngine` and a small pool of `AVAudioPlayerNode`s to play
/// pack clips with sub-100ms latency from trigger to first audio.
///
/// Clips are preloaded as `AVAudioPCMBuffer` at pack-switch time, never at
/// trigger time — disk I/O inside a trigger blows the latency budget.
///
/// See `AUDIO_NOTES.md` for the device-change, interruption, and mute handling
/// that the implementation must respect.
final class SoundEngine {}
