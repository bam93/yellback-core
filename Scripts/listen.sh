#!/usr/bin/env bash
#
# Run `yellback ... --listen` without re-rooting `.build/`.
#
# `sudo swift run yellback ...` causes the build artifacts in `.build/` to
# be created/touched as root. The next non-sudo `swift test` or `swift build`
# then fails with `Operation not permitted` until you `sudo chown -R` the
# directory back. To avoid that loop:
#
#   1. Build as the invoking user (artifacts stay user-owned).
#   2. `sudo` the already-built binary directly — no compilation inside sudo.
#
# Usage:
#   Scripts/listen.sh                                  # uses config.example.yaml
#   Scripts/listen.sh /tmp/yellback-debug.yaml         # custom config
#
# AccelerometerDetector requires root for the SPU sensor; MicDetector
# inherits the parent shell's TCC grant. Run from the repo root so the
# bundled `Resources/Packs/crowd/` resolves via the dev-mode cwd fallback.

set -euo pipefail

CONFIG="${1:-config.example.yaml}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

echo "==> swift build (as $(id -un))"
swift build

BINARY=".build/debug/yellback"
if [[ ! -x "$BINARY" ]]; then
    echo "error: $BINARY missing after build" >&2
    exit 1
fi

echo "==> sudo $BINARY --config $CONFIG --listen"
exec sudo "$BINARY" --config "$CONFIG" --listen
