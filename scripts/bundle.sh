#!/usr/bin/env bash
# Builds a release binary and assembles build/Still Here.app.
# Usage: scripts/bundle.sh [--dev]
#   --dev  ad-hoc sign the bundle (hardened runtime) so it can be launched locally.
#          package.sh signs with Developer ID instead and does not pass --dev.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEV_SIGN=0
BUILD_ARGUMENTS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV_SIGN=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

source "$ROOT/scripts/build-support.sh" "${BUILD_ARGUMENTS[@]}"
"$ROOT/scripts/check-version-sync.sh"

log "Building release binary (arm64)"
cd "$ROOT"
# Both executable products share one build graph and one incremental invocation.
python3 -B "$ROOT/scripts/build.py" swift build -c release --arch arm64
BIN_DIR="$(python3 -B "$ROOT/scripts/build.py" swift build -c release --arch arm64 --show-bin-path)"
for binary in "$APP_EXECUTABLE" "$CLI_NAME"; do
  [[ -x "$BIN_DIR/$binary" ]] || die "built binary not found at $BIN_DIR/$binary"
done

APP="$ROOT/build/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_EXECUTABLE" "$APP/Contents/MacOS/$APP_EXECUTABLE"
cp "$BIN_DIR/$CLI_NAME" "$APP/Contents/MacOS/$CLI_NAME"
cp "$ROOT/Packaging/Info.plist" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$PLIST"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -replace CFBundleExecutable -string "$APP_EXECUTABLE" "$PLIST"
plutil -lint "$PLIST" >/dev/null
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Best effort: extended attributes break codesign. The sandbox's provenance
# attribute cannot be removed and is harmless to signing.
xattr -cr "$APP" 2>/dev/null || true

if [[ $DEV_SIGN -eq 1 ]]; then
  log "Ad-hoc signing (dev)"
  # Nested code first: the app's signature seals the CLI's.
  codesign --force --options runtime --sign - "$APP/Contents/MacOS/$CLI_NAME"
  codesign --force --options runtime --sign - "$APP"
fi

log "Bundled $APP (version $VERSION)"
