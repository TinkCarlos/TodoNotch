#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/local.libo.todo-notch.plist"
APP_SUPPORT="$HOME/Library/Application Support/TodoNotch"
UID_NUM="$(id -u)"

echo "[1/4] Stopping TodoNotch LaunchAgent..."
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
pkill -x TodoNotch 2>/dev/null || true

echo "[2/4] Removing LaunchAgent plist..."
rm -f "$PLIST"

echo "[3/4] Removing TodoNotch local state ($APP_SUPPORT)..."
rm -rf "$APP_SUPPORT"

echo "[4/4] Removing TodoNotch.app bundle..."
rm -rf "$ROOT/TodoNotch.app"

echo "UNINSTALL_OK (User Vault & Agent configs preserved untouched)"
