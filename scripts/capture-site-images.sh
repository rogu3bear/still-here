#!/usr/bin/env bash
# Capture actual SwiftUI product views, using inert sample data and a fixed clock.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/build-support.sh"
cd "$ROOT"
python3 -B "$ROOT/scripts/build.py" swift build
mkdir -p build/capture-module-cache website/assets/images
python3 - <<'PY'
from pathlib import Path
import subprocess
import plistlib
import shutil
import struct
sources = sorted(str(p) for p in Path('Sources/StillHereApp').rglob('*.swift')
                 if p.name not in {'StillHereApp.swift', 'Previews.swift'})
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-default-isolation', 'MainActor',
                '-I', '.build/debug', '-module-cache-path', 'build/capture-module-cache',
                '.build/debug/StillHereCore.o', *sources,
                'scripts/capture-site-images.swift', '-o', 'build/stillhere-capture'], check=True)
for screen in ['settings', 'about']:
    bundle = Path(f'build/site-native/stillhere-{screen}.app')
    (bundle/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (bundle/'Contents/Resources').mkdir(parents=True, exist_ok=True)
    shutil.copy2('build/stillhere-capture', bundle/'Contents/MacOS/StillHereApp')
    shutil.copy2('Packaging/AppIcon.icns', bundle/'Contents/Resources/AppIcon.icns')
    info = plistlib.loads(Path('Packaging/Info.plist').read_bytes())
    info.update(CFBundleIdentifier=f'com.mlnavigator.stillhere.capture.{screen}', CFBundleShortVersionString=Path('VERSION').read_text().strip(), CFBundleVersion=Path('VERSION').read_text().strip(), CaptureScreen=screen, LSUIElement=False)
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['build/stillhere-capture', str(Path('website/assets/images').resolve())], check=True)
# Extract the app's existing 512px PNG chunk byte-for-byte; do not redraw it.
icon = Path('Packaging/AppIcon.icns').read_bytes()
offset = 8
while offset < len(icon):
    tag, length = struct.unpack('>4sI', icon[offset:offset+8])
    payload = icon[offset+8:offset+length]
    if tag == b'ic09' and payload.startswith(b'\x89PNG\r\n\x1a\n'):
        Path('website/assets/images/app-icon.png').write_bytes(payload)
        break
    offset += length
else:
    raise RuntimeError('AppIcon.icns has no native 512px PNG chunk')
PY

# General, Ignore List, and About images are captured from these displayed native
# windows with CUA; off-screen bitmap caching cannot capture the macOS tab chrome.
