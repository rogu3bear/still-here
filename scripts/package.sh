#!/usr/bin/env bash
# Builds, signs and verifies dist/stillhere-<VERSION>.pkg.
# Usage: scripts/package.sh [--notary-profile NAME] [--force]
#   --notary-profile NAME  notarize and staple with this notarytool keychain
#                          profile. Only this explicit argument enables
#                          notarization (the environment is ignored); without
#                          it nothing is sent to Apple.
#   --force                replace an existing dist/stillhere-<VERSION>.pkg.
# Identities can be overridden with APP_SIGN_ID and INSTALLER_SIGN_ID
# (a SHA-1 hash or the full certificate name).
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Deliberately not read from the environment: a stray NOTARY_PROFILE must never
# send anything to Apple.
NOTARY_PROFILE=""
FORCE=0
BUILD_ARGUMENTS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary-profile) NOTARY_PROFILE="${2:?--notary-profile needs a profile name}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

source "$ROOT/scripts/build-support.sh" "${BUILD_ARGUMENTS[@]}"
# Developer ID Application: MLNavigator Inc. (4JB58L7BTZ)
APP_SIGN_ID="${APP_SIGN_ID:-092DB0E5D9AC568FD4CD8D2C1D55A4EA0C09E71E}"
# Developer ID Installer: MLNavigator Inc. (4JB58L7BTZ)
INSTALLER_SIGN_ID="${INSTALLER_SIGN_ID:-D8CC67B106AC29F11A447991A0A659B5632D3CE4}"

APP="$ROOT/build/$APP_NAME.app"
COMPONENT="$ROOT/build/$PACKAGE_NAME-component.pkg"
PKG="$ROOT/dist/$PACKAGE_NAME-$VERSION.pkg"

if [[ -e "$PKG" ]]; then
  [[ $FORCE -eq 1 ]] || die "$PKG exists (bump VERSION, remove it, or pass --force)"
  rm -f "$PKG" "$PKG.sha256"
fi

# 1. Release build and bundle.
"$ROOT/scripts/bundle.sh"

# 2. Sign the app: hardened runtime, secure timestamp, no entitlements, no --deep.
log "Signing app with Developer ID Application"
# Nested code first: the app's signature seals the CLI's.
codesign --force --options runtime --timestamp --sign "$APP_SIGN_ID" "$APP/Contents/MacOS/$CLI_NAME"
codesign --force --options runtime --timestamp --sign "$APP_SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
grep -q 'flags=0x10000(runtime)' <<<"$SIGN_INFO" || die "hardened runtime flag missing"
grep -q "TeamIdentifier=$TEAM_ID" <<<"$SIGN_INFO" || die "TeamIdentifier is not $TEAM_ID"
grep -q '^Timestamp=' <<<"$SIGN_INFO" || die "secure timestamp missing"
[[ -z "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" ]] || die "unexpected entitlements"

# 3. Component package that installs Still Here.app into /Applications.
# pkgbuild stores any extended attribute as an AppleDouble ._ entry in the Bom and
# Payload. Stage a copy without xattrs, resource forks, quarantine or ACLs (the
# signature lives in the bundle, not in xattrs) and stop copyfile writing ._ files.
# Some hosts re-apply com.apple.provenance to every file their processes create and
# refuse to remove it, so the component is then rewritten without ._ entries.
log "Building component package"
export COPYFILE_DISABLE=1
STAGE="$ROOT/build/pkgroot"
rm -rf "$STAGE" "$COMPONENT"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$STAGE/$APP_NAME.app"
xattr -cr "$STAGE" 2>/dev/null || true
codesign --verify --deep --strict "$STAGE/$APP_NAME.app"
pkgbuild --analyze --root "$STAGE" "$ROOT/build/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$ROOT/build/component.plist"
pkgbuild --root "$STAGE" --component-plist "$ROOT/build/component.plist" \
  --identifier "$PKG_ID" --version "$VERSION" \
  --install-location /Applications "$COMPONENT"

# Rewrites the flat component without AppleDouble entries: filters the Bom, re-archives
# the Payload (same odc cpio + gzip, ownership, modes and times) and fixes the file count.
strip_appledouble() {
  local component="$1" work="$ROOT/build/component-expanded" count
  rm -rf "$work"
  pkgutil --expand "$component" "$work"
  lsbom "$work/Bom" | grep -v '/\._' > "$ROOT/build/component-bom.txt" || true
  rm -f "$work/Bom"
  mkbom -i "$ROOT/build/component-bom.txt" "$work/Bom"
  tar --format odc --exclude '._*' --no-mac-metadata --no-xattrs --no-acls \
    -czf "$work/Payload.clean" "@$work/Payload"
  mv "$work/Payload.clean" "$work/Payload"
  count="$(wc -l < "$ROOT/build/component-bom.txt" | tr -d ' ')"
  sed -i '' "s/numberOfFiles=\"[0-9]*\"/numberOfFiles=\"$count\"/" "$work/PackageInfo"
  rm -f "$component"
  pkgutil --flatten "$work" "$component"
  rm -rf "$work" "$ROOT/build/component-bom.txt"
}
COMPONENT_FILES="$(pkgutil --payload-files "$COMPONENT")"
if grep -q '/\._' <<<"$COMPONENT_FILES"; then
  log "Removing $(grep -c '/\._' <<<"$COMPONENT_FILES") AppleDouble entries that pkgbuild added for host-applied xattrs"
  strip_appledouble "$COMPONENT"
fi

# 3b. Component that links the CLI onto PATH. A symlink, not a copy: the binary stays
# sealed inside the signed app and updates with it.
log "Building CLI link component"
CLI_COMPONENT="$ROOT/build/$PACKAGE_NAME-cli-component.pkg"
CLI_STAGE="$ROOT/build/cliroot"
rm -rf "$CLI_STAGE" "$CLI_COMPONENT"
mkdir -p "$CLI_STAGE$(dirname "$CLI_LINK")"
ln -s "/Applications/$APP_NAME.app/Contents/MacOS/$CLI_NAME" "$CLI_STAGE$CLI_LINK"
pkgbuild --root "$CLI_STAGE" --identifier "$CLI_PKG_ID" --version "$VERSION" \
  --install-location / "$CLI_COMPONENT"
CLI_FILES="$(pkgutil --payload-files "$CLI_COMPONENT")"
if grep -q '/\._' <<<"$CLI_FILES"; then
  strip_appledouble "$CLI_COMPONENT"
fi

# 4. Product archive with the distribution file, signed with Developer ID Installer.
log "Building signed product archive"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@MIN_MACOS@/$MIN_MACOS/g" \
  "$ROOT/Packaging/distribution.xml" > "$ROOT/build/distribution.xml"
mkdir -p "$ROOT/dist"
productbuild --distribution "$ROOT/build/distribution.xml" --package-path "$ROOT/build" \
  --sign "$INSTALLER_SIGN_ID" --timestamp "$PKG"

# 5. Checks. All are hard failures except spctl, which rejects until notarized.
log "Verifying package"
pkgutil --check-signature "$PKG"
# Capture first: `pkgutil | grep -q` can SIGPIPE pkgutil and fail under pipefail.
PAYLOAD="$(pkgutil --payload-files "$COMPONENT"; pkgutil --payload-files "$CLI_COMPONENT")"
grep -qx ".$CLI_LINK" <<<"$PAYLOAD" || die "payload lacks .$CLI_LINK"
grep -qx "./$APP_NAME.app" <<<"$PAYLOAD" || die "payload lacks ./$APP_NAME.app"
for binary in "$APP_EXECUTABLE" "$CLI_NAME"; do
  grep -qx "./$APP_NAME.app/Contents/MacOS/$binary" <<<"$PAYLOAD" \
    || die "payload lacks ./$APP_NAME.app/Contents/MacOS/$binary"
done
if grep -q '/\._' <<<"$PAYLOAD"; then
  grep '/\._' <<<"$PAYLOAD" >&2
  die "AppleDouble ._ entries are in the payload"
fi
rm -rf "$ROOT/build/expanded" "$ROOT/build/full"
pkgutil --expand "$PKG" "$ROOT/build/expanded"
grep -q 'install-location="/Applications"' "$ROOT/build/expanded/$PACKAGE_NAME-component.pkg/PackageInfo" \
  || die "component install-location is not /Applications"
grep -q 'hostArchitectures="arm64"' "$ROOT/build/expanded/Distribution" \
  || die "distribution lacks the arm64 host requirement"
pkgutil --expand-full "$PKG" "$ROOT/build/full"
codesign --verify --deep --strict --verbose=2 "$ROOT/build/full/$PACKAGE_NAME-component.pkg/Payload/$APP_NAME.app"
LINK_TARGET="$(readlink "$ROOT/build/full/$PACKAGE_NAME-cli-component.pkg/Payload$CLI_LINK")"
[[ "$LINK_TARGET" == "/Applications/$APP_NAME.app/Contents/MacOS/$CLI_NAME" ]] \
  || die "CLI link points at '$LINK_TARGET'"
log "Payload links $CLI_LINK -> $LINK_TARGET"
log "Payload installs to /Applications/$APP_NAME.app"

set +e
spctl --assess --type execute -vv "$APP"; app_status=$?
spctl --assess --type install -vv "$PKG"; pkg_status=$?
set -e
echo "spctl app exit: $app_status, spctl pkg exit: $pkg_status"
if [[ $app_status -ne 0 || $pkg_status -ne 0 ]]; then
  echo "Gatekeeper rejects un-notarized Developer ID software (source=Unnotarized Developer ID); expected before notarization."
fi

# 6. Optional notarization, only with an explicit keychain profile.
if [[ -n "$NOTARY_PROFILE" ]]; then
  log "Notarizing with keychain profile '$NOTARY_PROFILE'"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
  xcrun stapler staple "$PKG"
  xcrun stapler validate "$PKG"
  spctl --assess --type install -vv "$PKG"
else
  cat <<EOF
Notarization skipped (no --notary-profile). To notarize:
  1. Store credentials once (Apple ID + app-specific password, or an App Store Connect API key):
       xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id $TEAM_ID
       xcrun notarytool store-credentials <profile> --key <AuthKey.p8> --key-id <id> --issuer <uuid>
  2. Rebuild and notarize:
       scripts/package.sh --force --notary-profile <profile>
EOF
fi

(cd "$ROOT/dist" && shasum -a 256 "$(basename "$PKG")" | tee "$(basename "$PKG").sha256")
# All payload and signature checks succeeded. Retain the app and installers;
# these exact staging copies are reproducible and no longer consumed.
# On any earlier failure they stay available for diagnosis.
rm -rf "$STAGE" "$CLI_STAGE" "$ROOT/build/expanded" "$ROOT/build/full"
log "Built $PKG"
