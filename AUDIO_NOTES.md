# Audio Engine Notes

Reference for anyone working on `SoundEngine.swift` or `SoundPack.swift`. AVAudioEngine has well-known sharp edges — this document catalogues them so we don't rediscover each one.

## AVAudioEngine Lifecycle

The engine has three lifecycle states that matter: not running, running, and interrupted. Transitions are not always obvious.

**Starting:** `engine.prepare()` then `engine.start()`. The `prepare()` call allocates buffers and is a useful place to fail early if the audio hardware isn't available. Skipping `prepare()` works most of the time but fails unpredictably on certain Bluetooth headsets.

**Stopping cleanly:** call `engine.stop()`. Do NOT just drop the reference — active player nodes may continue briefly and produce audible glitches on shutdown.

**Interruptions:** system-initiated interruptions (phone call, Siri, another app taking exclusive audio access) will pause the engine. Register for `AVAudioSession.interruptionNotification` and handle both the began/ended transitions. On "ended," check the options — sometimes the system expects you to resume, sometimes not.

## Device Changes

This is the #1 source of production bugs in AVAudioEngine apps.

When the user plugs in headphones, unplugs them, connects AirPods, or switches audio output via Control Center, the engine's `outputNode` format changes. Any player nodes connected to the output that were configured for the old format will stop working silently.

**The correct pattern:**
1. Listen for `AVAudioEngineConfigurationChangeNotification`
2. On notification, stop the engine
3. Disconnect all player nodes
4. Reconnect them with the new output format
5. Restart the engine

Do this even if it feels excessive. Users plug and unplug headphones constantly. An app that goes silent after you switch to AirPods is an app that gets uninstalled.

## Player Node Pool

A single `AVAudioPlayerNode` can only play one buffer at a time. For triggers that fire in rapid succession (priming state makes this common), we need multiple player nodes.

**Current design: pool of 8 pre-connected player nodes.**

All 8 are connected to the engine's `mainMixerNode` at startup. When a trigger fires:
1. Find the first player node with `!isPlaying`
2. Schedule the buffer on it: `node.scheduleBuffer(buffer, at: nil, options: .interrupts)`
3. Play: `node.play()`

If all 8 are busy (extremely rare even during heavy use), drop the trigger silently. Do NOT allocate a new node at trigger time — the allocation + connection takes 10–50ms and blows the latency budget.

Why 8? Empirical. 4 was enough for normal use but clipped during priming-state bursts. 16 added no observable benefit. 8 handles every test case we've tried with headroom.

## Clip Preloading

Every clip in the active pack is loaded into memory as `AVAudioPCMBuffer` at pack-switch time. This happens on a background queue — pack switches should not block.

**Why preload instead of stream:** disk I/O during a trigger is unpredictable. A spinning HDD or a slow SSD under load can add 50+ms of latency. Preloaded buffers are ready instantly.

**Memory cost:** a typical .caf clip is 20-100 KB. A pack with 90 clips (~30 per tier × 3 tiers) uses 2–10 MB of RAM. Acceptable.

**When to evict:** on `setPack(id:)`, the old pack's buffers are released. Don't keep multiple packs resident — the memory savings compound once we ship premium packs.

## Intensity-to-Volume Mapping

A trigger's intensity (0.0–1.0) maps to the player node's `volume` property. The mapping is NOT linear:

```
volume = pow(intensity, 0.7)
```

This gives more perceptual headroom at low intensities. A 0.3 intensity feels like about 40% volume, which is where users want quiet-but-present feedback. A linear mapping would make 0.3 feel like a whisper and 0.9 feel identical to 1.0.

The 0.7 exponent was tuned by ear on a MacBook Pro 14" at ~60% system volume. Revisit if users report either "can't hear quiet triggers" or "everything sounds the same volume."

## Tier Selection

A trigger's intensity determines which tier's clip pool is used:

- 0.0 – 0.33 → low tier
- 0.33 – 0.66 → medium tier
- 0.66 – 1.0 → high tier

Within a tier, selection is random with no-repeat (see below). The tier thresholds are hardcoded — they're not user-tunable and shouldn't be.

## No-Repeat Selection

Hearing the same clip twice in ten seconds shatters the illusion. The no-repeat rule:

1. Each tier maintains a `recentlyPlayed` set
2. When selecting a clip, exclude members of that set
3. If the remaining pool is empty (all clips recently played), clear the set and select freely
4. After a clip plays, add it to the set
5. Sets are cleared when the pack switches

The set is per-tier, not global. A low-tier clip playing doesn't affect high-tier selection.

## Respecting System Mute

If the system is muted, play nothing. This sounds obvious but AVAudioEngine will happily send audio to a muted output — the engine has no concept of user-level mute state.

Check `AVAudioSession.sharedInstance().outputVolume` before scheduling. If it's 0.0, skip the trigger entirely. Do NOT play at reduced volume "just in case" — the user muted for a reason.

On macOS specifically, the muted/unmuted state is surfaced via `AVAudioEngine.outputNode.outputVolume`. This differs from iOS's session model.

## Common Pitfalls

- **Scheduling a buffer on a player node that isn't connected:** silent failure. No error, no sound. Always verify the connection in the debugger if a trigger seems to swallow itself.
- **Using `AVAudioPlayer` instead of `AVAudioPlayerNode`:** higher latency, no control over the mixing graph. We don't use `AVAudioPlayer` anywhere in this package.
- **Reinstantiating the engine on config change:** don't. The engine has multi-second startup cost. Keep the engine alive for the app's lifetime; reconfigure in place.
- **Assuming 44.1 kHz / 16-bit:** the output node's format varies by hardware and system. Always read `outputNode.outputFormat(forBus: 0)` at startup and pass that to the mixer and player nodes.
