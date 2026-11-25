#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/todonotch-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

APP_STAGE="$STAGE/TodoNotch.app"

echo "[1/4] Building TodoNotch.app in isolated staging dir..."
if ARCH_MODE=universal APP_OUT="$APP_STAGE" VERSION="$VERSION" "$ROOT/scripts/build-app.sh"; then
  echo "Universal build succeeded."
else
  echo "Universal build failed; falling back to native architecture build..."
  ARCH_MODE=native APP_OUT="$APP_STAGE" VERSION="$VERSION" "$ROOT/scripts/build-app.sh"
fi

BIN_PATH="$APP_STAGE/Contents/MacOS/TodoNotch"
ARCHS="$(lipo -archs "$BIN_PATH" 2>/dev/null || uname -m)"
if [[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]]; then
  ARCH_LABEL="universal"
else
  ARCH_LABEL="$(echo "$ARCHS" | awk '{print $1}')"
fi

ln -s /Applications "$STAGE/Applications"

DIST_DIR="$ROOT/dist"
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/TodoNotch-v${VERSION}-macOS-${ARCH_LABEL}.dmg"

echo "[2/4] Creating compressed DMG: $DMG_PATH"
hdiutil create -volname "TodoNotch" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"

echo "[3/4] Verifying binary architectures and DMG checksum..."
lipo -info "$BIN_PATH"
shasum -a 256 "$DMG_PATH"
ls -lh "$DMG_PATH"

echo "[4/4] DMG ready: $DMG_PATH"
