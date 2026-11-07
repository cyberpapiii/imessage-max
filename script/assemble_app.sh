#!/usr/bin/env bash
# Builds and signs iMessage Max.app with the server helper inside it.
# Usage: assemble_app.sh <output .app path> <build configuration: release|debug>
# The configuration applies to the companion. The helper is always the release
# build from `make sign`, the binary whose path Full Disk Access names.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <output .app path> <release|debug>" >&2
  exit 2
fi
APP_BUNDLE="$1"
CONFIGURATION="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.cyberpapiii.imessage-max.menubar"

# Resolved once so an ad hoc warning prints once for both signatures.
SIGN_IDENTITY="$("$ROOT_DIR/script/signing_identity.sh")"
export SIGN_IDENTITY

swift build --package-path "$ROOT_DIR/macos" -c "$CONFIGURATION" --build-system native
MENU_BIN_DIR="$(swift build --package-path "$ROOT_DIR/macos" -c "$CONFIGURATION" --build-system native --show-bin-path)"
make -C "$ROOT_DIR/swift" sign
VERSION="$("$ROOT_DIR/scripts/check-version.sh" --print)"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$MENU_BIN_DIR/iMessageMaxMenu" "$APP_BUNDLE/Contents/MacOS/iMessageMaxMenu"
cp "$ROOT_DIR/swift/.build/release/imessage-max" "$APP_BUNDLE/Contents/Resources/imessage-max"
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

ICON_DIR="$(mktemp -d)"
trap 'rm -rf "$ICON_DIR"' EXIT
cat "$ROOT_DIR"/macos/Sources/MaxBrand/*.swift "$ROOT_DIR/script/render_app_icon.swift" > "$ICON_DIR/render_app_icon.swift"
swiftc -O "$ICON_DIR/render_app_icon.swift" -o "$ICON_DIR/render_app_icon"
"$ICON_DIR/render_app_icon" "$APP_BUNDLE/Contents/Resources"

# The helper was signed with its entitlements by `make sign`, and cp keeps
# that signature. The app gets hardened runtime and no entitlements.
"$ROOT_DIR/script/sign.sh" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
