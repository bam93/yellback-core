# YellBack Core — Config Schema

Canonical reference for the YAML config format consumed by `yellback-core`. The CLI (`yellback --config path/to/config.yaml`) reads this format. The paid Mac app writes this format when persisting user settings.

**This document and `config.example.yaml` must stay in sync.** If you add a field to one, add it to the other in the same commit.

## Location

By default, the CLI looks for config at `~/.config/yellback/config.yaml`. Override with `--config <path>`.

If the file doesn't exist, the CLI creates it by copying `config.example.yaml` on first run. If it exists but is malformed, the CLI exits non-zero with a clear error message and line number.

## Top-Level Structure

```yaml
triggers: { ... }
priming: { ... }
audio: { ... }
packs_directory: <path>
logging: { ... }
```

All five top-level keys are required. Unknown top-level keys cause a warning but don't fail loading (forward-compat with future config versions).

## `triggers`

Each of the three detectors has its own sub-block. A detector's entire block can be omitted, which is equivalent to `enabled: false` for that detector.

### `triggers.scream`

```yaml
scream:
  enabled: true                  # bool, default true
  dbfs_threshold: -20            # float, dBFS value (-60 to 0 sensible)
  sustain_seconds: 0.3           # float, minimum duration above threshold
  voice_band_filter: true        # bool, apply 200Hz-3kHz band-pass
  cooldown_seconds: 1.0          # float, time after firing before re-fire
```

**Tuning notes:**
- `dbfs_threshold`: -20 is a firm shout. -30 triggers on normal talking. -10 requires a full scream.
- `sustain_seconds`: below 0.2 fires on single claps. Above 0.5 misses short shouts.
- `voice_band_filter: false` is useful for debugging or non-human sound sources (dogs, TV) but increases false positives significantly.

### `triggers.rage_type`

```yaml
rage_type:
  enabled: true
  keystrokes_per_second_threshold: 8    # int, min 3, reasonable max ~20
  rolling_window_seconds: 2.0           # float, over how long to measure rate
  cooldown_seconds: 1.5
```

**Tuning notes:**
- Normal typing: 3–5 keystrokes/sec. Fast typing: 6–8. Rage typing: 8+.
- Setting below 6 makes everyone trigger constantly. Setting above 12 misses most rage-typing.
- `rolling_window_seconds` below 1.0 over-weights single burst; above 3.0 under-weights real events.

### `triggers.desk_bang`

```yaml
desk_bang:
  enabled: true
  g_force_threshold: 1.5         # float, delta from 1g baseline
  cooldown_seconds: 0.8
```

**Tuning notes:**
- 1.5g threshold fires on firm desk slams but not on typing or normal laptop movement.
- Below 1.0g: fires when user opens lid, picks up Mac, types hard.
- Above 2.5g: requires genuinely aggressive impact.
- Accelerometer profiles differ between MacBook Pro 14" and 16" — test both if changing defaults.

## `priming`

```yaml
priming:
  enabled: true
  window_seconds: 5.0              # float, duration of primed state
  threshold_multiplier: 0.75       # float, 0.5-1.0, applied to other triggers
```

**Semantics:**
- When any trigger fires, priming starts for `window_seconds`.
- During priming, other detectors' effective thresholds = base × `threshold_multiplier`.
- The trigger that started priming is NOT affected by its own priming (no auto-retrigger).
- If another trigger fires during priming, the window resets (not extends — resets to full length).

Setting `threshold_multiplier: 1.0` disables priming's effect while keeping the state machine running (useful for A/B testing). Setting below 0.5 causes cascade triggers.

## `audio`

```yaml
audio:
  master_volume: 0.8       # float 0.0-1.0, or null to follow system
  pack: crowd              # string, pack id
```

**`master_volume`:** if null (the default in the paid app), playback volume follows the system output volume. Setting a numeric value overrides that — useful for CLI users who want the app quieter than their overall system.

**`pack`:** must match a pack id available in `packs_directory`. If missing or invalid at startup, CLI falls back to the bundled Crowd pack and warns.

## `packs_directory`

```yaml
packs_directory: ~/.config/yellback/packs/
```

Absolute or tilde-expanded path. The directory is scanned at startup and on explicit reload. Each subdirectory is expected to contain a valid `pack.yaml`.

If the directory doesn't exist, the CLI creates it. If it exists but contains no valid packs, the CLI uses only the bundled Crowd pack.

The paid Mac app uses `~/Library/Application Support/YellBack/packs/` instead.

## `logging`

```yaml
logging:
  level: info     # debug | info | warn | error
```

Simple level-based logging. `debug` prints every detector tick and is very noisy. `info` prints lifecycle events and trigger firings. `warn` prints only recoverable problems. `error` prints only fatal conditions.

Logs go to stderr. There is no file-based logging — if users want to save logs, they redirect stderr.

## Full Example

See `config.example.yaml` at the repo root. Copy it to `~/.config/yellback/config.yaml` and edit.

## Schema Version & Migration

The config format is currently unversioned. Breaking changes in the future will introduce a `schema_version` key and a migration path. Until then, additions are backward-compatible (new keys get defaults if missing).

## Validation Rules (enforced at load)

The following cause load failures:
- Non-numeric values in numeric fields
- `dbfs_threshold > 0` or `< -60`
- `keystrokes_per_second_threshold < 1`
- `g_force_threshold <= 0`
- Any `cooldown_seconds < 0`
- Any `_seconds` field > 60 (likely user error, not a real value)
- `master_volume` outside [0.0, 1.0] when non-null
- `threshold_multiplier` outside [0.1, 1.0]
- Invalid `logging.level`
- `packs_directory` path that can neither be read nor created

Everything else is accepted with warnings if suspicious.
