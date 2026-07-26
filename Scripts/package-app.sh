#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product LocalClip
BIN="$(swift build -c release --show-bin-path)/LocalClip"
APP="$ROOT/dist/LocalClip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LocalClip"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/LocalClip"

# ad-hoc sign for local run (Gatekeeper may still prompt)
if command -v codesign >/dev/null; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "Built: $APP"
echo "Run: open '$APP'"
