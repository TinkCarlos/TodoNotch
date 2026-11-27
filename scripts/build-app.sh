#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH_MODE="${ARCH_MODE:-native}"
APP_OUT="${APP_OUT:-$ROOT/TodoNotch.app}"
VERSION="${VERSION:-1.0.0}"

echo "[1/4] Building TodoNotch (release, arch=$ARCH_MODE)..."
if [ "$ARCH_MODE" = "universal" ]; then
  swift build -c release --arch arm64 --arch x86_64 --product TodoNotch
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  BIN="$BIN_DIR/TodoNotch"
else
  swift build -c release --product TodoNotch
  BIN_DIR="$(swift build -c release --show-bin-path)"
  BIN="$BIN_DIR/TodoNotch"
fi

if [ ! -f "$BIN" ]; then
  echo "ERROR: Built binary not found at $BIN" >&2
  exit 1
fi

mkdir -p "$APP_OUT/Contents/MacOS" "$APP_OUT/Contents/Resources"

# Atomic swap avoids crashing an already-running local TodoNotch instance
cp "$BIN" "$APP_OUT/Contents/MacOS/TodoNotch.tmp"
chmod +x "$APP_OUT/Contents/MacOS/TodoNotch.tmp"
mv -f "$APP_OUT/Contents/MacOS/TodoNotch.tmp" "$APP_OUT/Contents/MacOS/TodoNotch"

if [ -f "$ROOT/scan_todos.py" ]; then
  cp "$ROOT/scan_todos.py" "$APP_OUT/Contents/Resources/scan_todos.py"
  chmod +x "$APP_OUT/Contents/Resources/scan_todos.py"
fi

cp "$ROOT/scripts/agy_bridge_sidecar.mjs" "$APP_OUT/Contents/Resources/agy_bridge_sidecar.mjs"

ICON_PLIST=""
if [ -f "$ROOT/Assets/AppIcon.icns" ]; then
  cp "$ROOT/Assets/AppIcon.icns" "$APP_OUT/Contents/Resources/AppIcon.icns"
  ICON_PLIST=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>'
fi

cat > "$APP_OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>TodoNotch</string>
  <key>CFBundleIdentifier</key>
  <string>com.libo.TodoNotch</string>
  <key>CFBundleName</key>
  <string>TodoNotch</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
${ICON_PLIST}
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"TodoNotch Local Dev"'; then
    SIGN_IDENTITY="TodoNotch Local Dev"
  else
    SIGN_IDENTITY="-"
  fi
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "[2/4] Ad-hoc signing bundle..."
  codesign --force --deep --sign - "$APP_OUT"
else
  echo "[2/4] Signing bundle with '$SIGN_IDENTITY'..."
  codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP_OUT"
fi

echo "[3/4] Built bundle: $APP_OUT ($(du -sh "$APP_OUT/Contents/MacOS/TodoNotch" | awk '{print $1}'))"
echo "[4/4] Done."
