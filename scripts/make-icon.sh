#!/usr/bin/env bash
# Regenerates Packaging/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$ROOT/scripts/build-support.sh"

WORK="$ROOT/build/icon"
SET="$WORK/AppIcon.iconset"
rm -rf "$WORK"
mkdir -p "$SET"

log "Drawing master icon"
swift "$ROOT/scripts/make-icon.swift" "$WORK/icon_1024.png"

log "Scaling iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o "$ROOT/Packaging/AppIcon.icns"
log "Wrote Packaging/AppIcon.icns"
