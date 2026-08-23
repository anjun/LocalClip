#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source "$ROOT/Scripts/install-path.sh"
source "$ROOT/Scripts/swift-env.sh"
localclip_configure_swift_env "$ROOT"

swift build -c release --product LocalClip
BIN="$(swift build -c release --show-bin-path)/LocalClip"

# Reuse the existing install location so one bundle ID never fans out into two
# independently signed apps.
INSTALL_DIR="$(localclip_install_dir)"
localclip_warn_duplicate_install
mkdir -p "$INSTALL_DIR" "$ROOT/dist"
APP_DIST="$ROOT/dist/LocalClip.app"
APP_INSTALL="$INSTALL_DIR/LocalClip.app"

package_into() {
  local APP="$1"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/LocalClip"
  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
  # App icon (Finder, Accessibility list, Force Quit, etc.)
  if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  fi
  # Optional monochrome template for menu bar (if present)
  if [[ -f "$ROOT/Resources/StatusBarIcon.png" ]]; then
    cp "$ROOT/Resources/StatusBarIcon.png" "$APP/Contents/Resources/StatusBarIcon.png"
  fi
  # PkgInfo helps LaunchServices treat us as a real app
  printf 'APPL????' > "$APP/Contents/PkgInfo"
  chmod +x "$APP/Contents/MacOS/LocalClip"
  xattr -cr "$APP" 2>/dev/null || true
  # Ad-hoc sign with a stable designated requirement. Default ad-hoc DR is a
  # CDHash, so every rebuild looks like a new app to Screen Recording TCC and
  # `screencapture` can only grab the wallpaper.
  if command -v codesign >/dev/null; then
    local req='=designated => identifier "com.localclip.app"'
    codesign --force --sign - --identifier "com.localclip.app" --requirements "$req" \
      "$APP/Contents/MacOS/LocalClip"
    codesign --force --sign - --identifier "com.localclip.app" --requirements "$req" \
      "$APP"
  fi
}

package_into "$APP_DIST"
rm -rf "$APP_INSTALL"
/usr/bin/ditto "$APP_DIST" "$APP_INSTALL"

echo "Built: $APP_DIST"
echo "Installed: $APP_INSTALL"
echo "Run: open '$APP_INSTALL'"
echo "Note: After rebuild, re-check Accessibility toggle for LocalClip if auto-paste fails."
