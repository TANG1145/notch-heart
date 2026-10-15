#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Notch Heart.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NotchHeart" "$APP/Contents/MacOS/NotchHeart"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Finder may attach cosmetic metadata when inspecting a prior local build.
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --sign - --identifier dev.tang.notchheart "$APP"
codesign --verify --strict "$APP"
ARCH="$(uname -m)"
ditto --norsrc --noextattr -c -k --keepParent "$APP" "$ROOT/dist/NotchHeart-macOS-$ARCH.zip"
echo "$APP"
