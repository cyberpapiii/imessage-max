#!/usr/bin/env bash
# Builds and signs iMessage Max.app with the server helper inside it.
# Usage: assemble_app.sh <output .app path> <build configuration: release|debug>
# The configuration applies to the companion. The helper is always the release
# build from `make sign`.
#
# The helper runs from Contents/MacOS under SMAppService, using the agent plist
# in Contents/Library/LaunchAgents, so macOS charges its privacy access to the
# app. A test build that must run next to the real app overrides APP_NAME,
# APP_BUNDLE_ID, HELPER_LABEL, HELPER_PORT, HELPER_SOCKET and HELPER_TOKEN_FILE,
# so it shares no registration, port, socket, token or log with it.
# HELPER_SOCKET and HELPER_TOKEN_FILE become the helper's --socket-path and
# --token-file, whose folders must already exist with mode 0700.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <output .app path> <release|debug>" >&2
  exit 2
fi
APP_BUNDLE="$1"
CONFIGURATION="$2"
case "$APP_BUNDLE" in
  *.app) ;;
  *) echo "The output path must end in .app: $APP_BUNDLE" >&2; exit 2 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_TEMPLATE="$ROOT_DIR/macos/Resources/LaunchAgents/com.cyberpapiii.imessage-max.helper.plist"
ENTITLEMENTS="$ROOT_DIR/swift/iMessageMax.entitlements"
APP_NAME="${APP_NAME:-iMessage Max}"
BUNDLE_ID="${APP_BUNDLE_ID:-com.cyberpapiii.imessage-max.menubar}"
HELPER_LABEL="${HELPER_LABEL:-$(plutil -extract Label raw -o - "$AGENT_TEMPLATE")}"
HELPER_PORT="${HELPER_PORT:-}"
HELPER_SOCKET="${HELPER_SOCKET:-}"
HELPER_TOKEN_FILE="${HELPER_TOKEN_FILE:-}"

# Resolved once so an ad hoc warning prints once for both signatures.
SIGN_IDENTITY="$("$ROOT_DIR/script/signing_identity.sh")"
export SIGN_IDENTITY

swift build --package-path "$ROOT_DIR/macos" -c "$CONFIGURATION" --build-system native
MENU_BIN_DIR="$(swift build --package-path "$ROOT_DIR/macos" -c "$CONFIGURATION" --build-system native --show-bin-path)"
make -C "$ROOT_DIR/swift" sign
VERSION="$("$ROOT_DIR/scripts/check-version.sh" --print)"

# A fresh bundle every time. Copying over a binary that is running makes macOS
# kill that process, and a stale file from an older layout would stay sealed.
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" \
  "$APP_BUNDLE/Contents/Library/LaunchAgents"
cp "$MENU_BIN_DIR/iMessageMaxMenu" "$APP_BUNDLE/Contents/MacOS/iMessageMaxMenu"
cp "$ROOT_DIR/swift/.build/release/imessage-max" "$APP_BUNDLE/Contents/MacOS/imessage-max"
# The Claude Desktop extension's manifest and icons. The companion packs them
# with the helper above into a .mcpb when the user connects Claude.
mkdir -p "$APP_BUNDLE/Contents/Resources/mcpb"
cp "$ROOT_DIR/mcpb/manifest.json" "$APP_BUNDLE/Contents/Resources/mcpb/manifest.json"
cp -R "$ROOT_DIR/mcpb/assets" "$APP_BUNDLE/Contents/Resources/mcpb/assets"

AGENT_PLIST="$APP_BUNDLE/Contents/Library/LaunchAgents/$HELPER_LABEL.plist"
cp "$AGENT_TEMPLATE" "$AGENT_PLIST"
plutil -replace Label -string "$HELPER_LABEL" "$AGENT_PLIST"
plutil -replace AssociatedBundleIdentifiers -json "[\"$BUNDLE_ID\"]" "$AGENT_PLIST"
INDEX=0
while ARG="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$INDEX" "$AGENT_PLIST" 2>/dev/null)"; do
  NEXT=$((INDEX + 1))
  if [ "$ARG" = "--port" ] && [ -n "$HELPER_PORT" ]; then
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:$NEXT $HELPER_PORT" "$AGENT_PLIST"
  elif [ "$ARG" = "--log-file" ]; then
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:$NEXT ~/Library/Logs/$APP_NAME/imessage-max.log" "$AGENT_PLIST"
  fi
  INDEX=$NEXT
done
if [ -n "$HELPER_SOCKET" ]; then
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments: string --socket-path" \
    -c "Add :ProgramArguments: string $HELPER_SOCKET" "$AGENT_PLIST"
fi
if [ -n "$HELPER_TOKEN_FILE" ]; then
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments: string --token-file" \
    -c "Add :ProgramArguments: string $HELPER_TOKEN_FILE" "$AGENT_PLIST"
fi
plutil -lint -s "$AGENT_PLIST"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>iMessageMaxMenu</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
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

ICON_DIR="$(mktemp -d)"
trap 'rm -rf "$ICON_DIR"' EXIT
cat "$ROOT_DIR"/macos/Sources/MaxBrand/*.swift "$ROOT_DIR/script/render_app_icon.swift" > "$ICON_DIR/render_app_icon.swift"
swiftc -O "$ICON_DIR/render_app_icon.swift" -o "$ICON_DIR/render_app_icon"
"$ICON_DIR/render_app_icon" "$APP_BUNDLE/Contents/Resources"

# Inside out. `make sign` signed the helper with its entitlements and cp kept
# that signature. The app needs the same entitlements, because macOS charges
# the in-bundle helper's Contacts and Apple Events access to the app.
"$ROOT_DIR/script/sign.sh" "$APP_BUNDLE" --entitlements "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP_BUNDLE"
