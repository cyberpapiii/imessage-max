#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="iMessage Max"
BUNDLE_ID="com.cyberpapiii.imessage-max.menubar"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INSTALL_BUNDLE="$HOME/Applications/$APP_NAME.app"
case "$MODE" in
  run|--verify|--build-only|--install|--logs|--telemetry|--debug) ;;
  *) echo "usage: $0 [--verify|--build-only|--install|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac

pkill -x iMessageMaxMenu >/dev/null 2>&1 || true
swift build --package-path "$ROOT_DIR/macos" -c release --build-system native
MENU_BIN_DIR="$(swift build --package-path "$ROOT_DIR/macos" -c release --build-system native --show-bin-path)"
SERVER_BINARY="$ROOT_DIR/swift/.build/release/imessage-max"
make -C "$ROOT_DIR/swift" sign
VERSION="$("$ROOT_DIR/scripts/check-version.sh" --print)"
SIGN_HASH="$(security find-identity -v -p codesigning | awk '/"iMessage Max Dev"/ { print $2; exit }')"
if [ -z "$SIGN_HASH" ]; then
  echo "Persistent signing identity missing. Run: cd swift && make setup-signing" >&2
  exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$MENU_BIN_DIR/iMessageMaxMenu" "$APP_BUNDLE/Contents/MacOS/iMessageMaxMenu"
cp "$SERVER_BINARY" "$APP_BUNDLE/Contents/Resources/imessage-max"
cp "$ROOT_DIR/swift/launchd/local.imessage-max.plist" "$APP_BUNDLE/Contents/Resources/local.imessage-max.plist"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>iMessageMaxMenu</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>iMessage Max</string>
<key>CFBundleDisplayName</key><string>iMessage Max</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSContactsUsageDescription</key><string>iMessage Max uses Contacts to put familiar names to phone numbers.</string>
<key>NSAppleEventsUsageDescription</key><string>iMessage Max needs access to Messages so your assistants can send messages when you ask.</string>
</dict></plist>
PLIST
ICON_RENDERER="$ROOT_DIR/dist/render_app_icon.swift"
cat "$ROOT_DIR"/macos/Sources/MaxBrand/*.swift "$ROOT_DIR/script/render_app_icon.swift" > "$ICON_RENDERER"
swiftc -O "$ICON_RENDERER" -o "$ROOT_DIR/dist/render_app_icon"
"$ROOT_DIR/dist/render_app_icon" "$APP_BUNDLE/Contents/Resources"
codesign --force --sign "$SIGN_HASH" "$APP_BUNDLE/Contents/Resources/imessage-max"
codesign --force --sign "$SIGN_HASH" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

LAUNCH_BUNDLE="$APP_BUNDLE"
if [ "$MODE" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  if [ -e "$INSTALL_BUNDLE" ]; then
    INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALL_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$INSTALLED_ID" != "$BUNDLE_ID" ]; then
      echo "A different app already exists at $INSTALL_BUNDLE; leaving it untouched." >&2
      exit 1
    fi
  fi
  ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
  LAUNCH_BUNDLE="$INSTALL_BUNDLE"
fi

case "$MODE" in
  --build-only) echo "Built and signed: $APP_BUNDLE" ;;
  --debug) lldb -- "$LAUNCH_BUNDLE/Contents/MacOS/iMessageMaxMenu" ;;
  *)
    /usr/bin/open -n "$LAUNCH_BUNDLE"
    if [ "$MODE" = "--verify" ] || [ "$MODE" = "--install" ]; then
      sleep 1
      pgrep -x iMessageMaxMenu >/dev/null
      echo "Running: $LAUNCH_BUNDLE"
    fi
    if [ "$MODE" = "--logs" ] || [ "$MODE" = "--telemetry" ]; then
      /usr/bin/log stream --info --style compact --predicate "process == 'iMessageMaxMenu'"
    fi
    ;;
esac
