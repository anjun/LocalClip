#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) LocalClip.app and package for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo "1.0.0")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist 2>/dev/null || echo "1")"
PRODUCT_NAME="LocalClip"
BUNDLE_ID="com.localclip.app"
MIN_MACOS="13.0"

DIST="$ROOT/dist"
APP="$DIST/${PRODUCT_NAME}.app"
STAGE="$DIST/universal-build"
ZIP_NAME="${PRODUCT_NAME}-${VERSION}-universal-macos.zip"
DMG_NAME="${PRODUCT_NAME}-${VERSION}-universal-macos.dmg"
INSTALL_DIR="${HOME}/Applications"

echo "==> LocalClip release ${VERSION} (build ${BUILD})"
echo "    Target: universal macOS (arm64 + x86_64), minimum ${MIN_MACOS}"

rm -rf "$STAGE" "$APP"
mkdir -p "$STAGE" "$DIST" "$INSTALL_DIR"

build_arch() {
  local arch="$1"
  echo "==> Building ${arch}…"
  # Per-arch build path so binaries don't overwrite each other.
  local conf="release-${arch}"
  swift build -c release \
    --product LocalClip \
    --arch "$arch" \
    --build-path "$STAGE/swift-${arch}" \
    -Xswiftc "-target" -Xswiftc "${arch}-apple-macosx${MIN_MACOS}"

  # Prefer SwiftPM show-bin-path; fall back to find (exclude dSYM junk).
  local bin
  bin="$(swift build -c release --product LocalClip --arch "$arch" \
    --build-path "$STAGE/swift-${arch}" --show-bin-path 2>/dev/null)/LocalClip"
  if [[ ! -f "$bin" ]]; then
    bin="$(find "$STAGE/swift-${arch}" -type f -name LocalClip \
      ! -path '*.dSYM*' \
      ! -path '*/DWARF/*' \
      -perm -111 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "${bin:-}" || ! -f "$bin" ]]; then
    echo "error: could not find LocalClip binary for ${arch}" >&2
    find "$STAGE/swift-${arch}" -name LocalClip 2>/dev/null || true
    exit 1
  fi
  if ! file "$bin" | grep -q 'Mach-O'; then
    echo "error: not a Mach-O binary: $bin ($(file "$bin"))" >&2
    exit 1
  fi
  # Confirm architecture slice present
  if ! lipo -info "$bin" 2>/dev/null | grep -q "$arch"; then
    if ! file "$bin" | grep -qi "$arch"; then
      echo "warning: binary may not match ${arch}: $(file "$bin")" >&2
    fi
  fi
  cp "$bin" "$STAGE/LocalClip-${arch}"
  chmod +x "$STAGE/LocalClip-${arch}"
  echo "    ${arch}: $bin"
  lipo -info "$STAGE/LocalClip-${arch}" || file "$STAGE/LocalClip-${arch}"
}

build_arch arm64
build_arch x86_64

echo "==> Creating universal binary (lipo)…"
lipo -create \
  "$STAGE/LocalClip-arm64" \
  "$STAGE/LocalClip-x86_64" \
  -output "$STAGE/LocalClip"
lipo -info "$STAGE/LocalClip"
file "$STAGE/LocalClip"

echo "==> Assembling ${PRODUCT_NAME}.app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$STAGE/LocalClip" "$APP/Contents/MacOS/LocalClip"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$ROOT/Resources/StatusBarIcon.png" ]]; then
  cp "$ROOT/Resources/StatusBarIcon.png" "$APP/Contents/Resources/StatusBarIcon.png"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/LocalClip"

# Strip quarantine from build tree pieces we control
xattr -cr "$APP" 2>/dev/null || true

echo "==> Ad-hoc codesign (stable id, no hardened runtime)…"
if command -v codesign >/dev/null; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/LocalClip"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  codesign --verify --verbose=1 "$APP" 2>&1 || true
fi

# Install for local use (stable TCC identity path)
echo "==> Installing to ${INSTALL_DIR}/${PRODUCT_NAME}.app…"
rm -rf "${INSTALL_DIR}/${PRODUCT_NAME}.app"
cp -R "$APP" "${INSTALL_DIR}/${PRODUCT_NAME}.app"
xattr -cr "${INSTALL_DIR}/${PRODUCT_NAME}.app" 2>/dev/null || true
if command -v codesign >/dev/null; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "${INSTALL_DIR}/${PRODUCT_NAME}.app" 2>/dev/null || true
fi

echo "==> ZIP package…"
rm -f "$DIST/$ZIP_NAME"
(
  cd "$DIST"
  # zip from parent of .app so archive root is LocalClip.app
  ditto -c -k --keepParent "${PRODUCT_NAME}.app" "$ZIP_NAME"
)
echo "    $DIST/$ZIP_NAME"

echo "==> DMG package…"
rm -f "$DIST/$DMG_NAME"
DMG_STAGE="$STAGE/dmg"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/${PRODUCT_NAME}.app"
# Convenience link for drag-install UX
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "${PRODUCT_NAME} ${VERSION}" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DIST/$DMG_NAME"
echo "    $DIST/$DMG_NAME"

# Cleanup intermediate object trees (keep final artifacts)
rm -rf "$STAGE"

echo ""
echo "=========================================="
echo " Release ready (universal Intel + Apple silicon)"
echo "  App:  $APP"
echo "  ZIP:  $DIST/$ZIP_NAME"
echo "  DMG:  $DIST/$DMG_NAME"
echo "  Install: ${INSTALL_DIR}/${PRODUCT_NAME}.app"
echo ""
echo "  lipo: $(lipo -info "$APP/Contents/MacOS/LocalClip" 2>/dev/null || true)"
echo "  open: open '${INSTALL_DIR}/${PRODUCT_NAME}.app'"
echo "=========================================="
