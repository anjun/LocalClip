#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product LocalClip
BIN="$(swift build -c release --show-bin-path)/LocalClip"

# Prefer stable user Applications path so TCC/Accessibility identity stays consistent.
INSTALL_DIR="${HOME}/Applications"
mkdir -p "$INSTALL_DIR" "$ROOT/dist"
APP_DIST="$ROOT/dist/LocalClip.app"
APP_INSTALL="$INSTALL_DIR/LocalClip.app"

package_into() {
  local APP="$1"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/LocalClip"
  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
  # PkgInfo helps LaunchServices treat us as a real app
  printf 'APPL????' > "$APP/Contents/PkgInfo"
  chmod +x "$APP/Contents/MacOS/LocalClip"
  xattr -cr "$APP" 2>/dev/null || true
  # Ad-hoc sign with stable identifier (no hardened runtime — that can break Accessibility)
  if command -v codesign >/dev/null; then
    codesign --force --sign - --identifier "com.localclip.app" "$APP/Contents/MacOS/LocalClip" 2>/dev/null || true
    codesign --force --sign - --identifier "com.localclip.app" "$APP" 2>/dev/null || true
  fi
}

package_into "$APP_DIST"
package_into "$APP_INSTALL"

echo "Built: $APP_DIST"
echo "Installed: $APP_INSTALL"
echo "Run: open '$APP_INSTALL'"
echo "Note: After rebuild, re-check Accessibility toggle for LocalClip if auto-paste fails."
