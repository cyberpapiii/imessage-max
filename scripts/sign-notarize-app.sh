#!/usr/bin/env bash
# Builds iMessage Max.app, notarizes and staples it, wraps it in a signed,
# notarized and stapled DMG, and checks the result before anything uploads.
#
# Usage: sign-notarize-app.sh [--local] <output dir>
#
# Environment:
#   MACOS_SIGNING_IDENTITY   Developer ID Application certificate SHA-1
#   MACOS_CERTIFICATE_P12    base64 p12 holding that identity (not with --local)
#   MACOS_CERTIFICATE_PASS   the p12's password (not with --local)
#   MACOS_NOTARY_KEY_P8      base64 App Store Connect API key
#   MACOS_NOTARY_KEY_ID      that key's id
#   MACOS_NOTARY_ISSUER_ID   that key's issuer id
#
# --local signs from the keychains already on the search list instead of
# importing the p12 into a temporary keychain.
set -euo pipefail

TEAM_ID="HJF7LN64XX"
HELPER_ID="com.cyberpapiii.imessage-max"
APP_ID="com.cyberpapiii.imessage-max.menubar"
AGENT_LABEL="com.cyberpapiii.imessage-max.helper"
# The helper and the app both carry these: macOS charges the in-bundle
# helper's Contacts and Apple Events access to the app.
ENTITLEMENTS=(
  com.apple.security.automation.apple-events
  com.apple.security.personal-information.addressbook
)

LOCAL=0
if [[ "${1:-}" == "--local" ]]; then
  LOCAL=1
  shift
fi
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 [--local] <output dir>" >&2
  exit 2
fi
OUT_DIR="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "error: $*" >&2; exit 1; }

REQUIRED=(MACOS_SIGNING_IDENTITY MACOS_NOTARY_KEY_P8 MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID)
[[ "$LOCAL" -eq 1 ]] || REQUIRED+=(MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASS)
for var in "${REQUIRED[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "error: $var is not set" >&2; exit 2; }
done

VERSION="$("$ROOT_DIR/scripts/check-version.sh" --print)"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" && "${GITHUB_REF_NAME:-}" != "v$VERSION" ]]; then
  fail "tag ${GITHUB_REF_NAME:-} does not match Version.swift $VERSION"
fi

WORK_DIR="$(mktemp -d)"
KEYCHAIN="$WORK_DIR/build.keychain-db"
ORIGINAL_KEYCHAINS=()
cleanup() {
  if [[ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || true
  fi
  if [[ -f "$KEYCHAIN" ]]; then
    security delete-keychain "$KEYCHAIN" || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ "$LOCAL" -eq 0 ]]; then
  KEYCHAIN_LIST="$(security list-keychains -d user)" || fail "cannot read the keychain search list"
  [[ -n "$KEYCHAIN_LIST" ]] || fail "the keychain search list is empty"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    ORIGINAL_KEYCHAINS+=("${line//\"/}")
  done <<<"$KEYCHAIN_LIST"
  KEYCHAIN_PASS="$(head -c 32 /dev/urandom | base64)"
  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$WORK_DIR/certificate.p12"
  security import "$WORK_DIR/certificate.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASS" -T /usr/bin/codesign
  rm -f "$WORK_DIR/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
  # codesign finds an identity by hash only on the search list.
  security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
fi
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -qF "$MACOS_SIGNING_IDENTITY" <<<"$IDENTITIES" || fail "identity $MACOS_SIGNING_IDENTITY is not on the keychain search list"
export SIGN_IDENTITY="$MACOS_SIGNING_IDENTITY"

NOTARY_KEY="$WORK_DIR/notary.p8"
printf '%s' "$MACOS_NOTARY_KEY_P8" | base64 --decode > "$NOTARY_KEY"
chmod 600 "$NOTARY_KEY"
# Keep the credentials out of the environment of every build step below.
unset MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASS MACOS_NOTARY_KEY_P8
NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$MACOS_NOTARY_KEY_ID" --issuer "$MACOS_NOTARY_ISSUER_ID")

notarize() {
  local artifact="$1" result="$WORK_DIR/notary-result.json" status id
  xcrun notarytool submit "$artifact" "${NOTARY_AUTH[@]}" --wait --timeout 30m \
    --output-format json > "$result" || true
  cat "$result"
  echo
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  echo "status: ${status:-none}"
  if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      echo "==> Notary log for $id" >&2
      xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    echo "error: notarization of $(basename "$artifact") was not Accepted" >&2
    exit 1
  fi
}

STAGE="$WORK_DIR/dmg"
APP="$STAGE/iMessage Max.app"
HELPER="$APP/Contents/MacOS/imessage-max"
MENU="$APP/Contents/MacOS/iMessageMaxMenu"
AGENT_PLIST="$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist"
DMG_NAME="iMessage-Max-$VERSION.dmg"
DMG="$WORK_DIR/$DMG_NAME"

echo "==> Assembling $APP"
mkdir -p "$STAGE"
"$ROOT_DIR/script/assemble_app.sh" "$APP" release

echo "==> Checking the app"
for bin in "$HELPER" "$MENU"; do
  [[ "$(lipo -archs "$bin")" == "arm64" ]] || fail "$bin is not arm64-only: $(lipo -archs "$bin")"
  details="$(codesign -dvv "$bin" 2>&1)"
  grep -q "flags=0x10000(runtime)" <<<"$details" || fail "$bin lacks hardened runtime"
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "$bin is not signed by team $TEAM_ID"
  links="$(otool -L "$bin")"
  echo "$links"
  # A non-weak link fails to load on macOS 15, which lacks this dylib.
  if awk '/libswiftCompatibilitySpan\.dylib/ && !/, weak\)/ { found = 1 } END { exit !found }' <<<"$links"; then
    fail "$bin links libswiftCompatibilitySpan.dylib non-weak"
  fi
done
grep -qx "Identifier=$HELPER_ID" <<<"$(codesign -dvv "$HELPER" 2>&1)" || fail "helper identifier is not $HELPER_ID"
grep -qx "Identifier=$APP_ID" <<<"$(codesign -dvv "$APP" 2>&1)" || fail "app identifier is not $APP_ID"
for signed in "$HELPER" "$APP"; do
  entitlements="$(codesign -d --entitlements - --xml "$signed" 2>/dev/null)"
  for key in "${ENTITLEMENTS[@]}"; do
    grep -A1 "<key>$key</key>" <<<"$entitlements" | grep -q "<true/>" || fail "$signed lacks entitlement $key"
  done
done
[[ -f "$AGENT_PLIST" ]] || fail "the agent plist $AGENT_PLIST is missing"
[[ "$(plutil -extract Label raw -o - "$AGENT_PLIST")" == "$AGENT_LABEL" ]] \
  || fail "the agent plist's Label is not $AGENT_LABEL"
[[ "$(plutil -extract BundleProgram raw -o - "$AGENT_PLIST")" == "Contents/MacOS/imessage-max" ]] \
  || fail "the agent plist's BundleProgram is not Contents/MacOS/imessage-max"
plutil -extract AssociatedBundleIdentifiers json -o - "$AGENT_PLIST" | grep -qF "\"$APP_ID\"" \
  || fail "the agent plist does not associate $APP_ID"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "app version $APP_VERSION is not $VERSION"
HELPER_VERSION="$("$HELPER" --version)"
[[ "$HELPER_VERSION" == *"$VERSION"* ]] || fail "helper reports '$HELPER_VERSION', not $VERSION"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$WORK_DIR/app.zip"
notarize "$WORK_DIR/app.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"

echo "==> Building $DMG_NAME"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "iMessage Max" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

mkdir -p "$OUT_DIR"
mv "$DMG" "$OUT_DIR/$DMG_NAME"
echo "$OUT_DIR/$DMG_NAME $(du -h "$OUT_DIR/$DMG_NAME" | cut -f1) sha256 $(shasum -a 256 "$OUT_DIR/$DMG_NAME" | cut -d' ' -f1)"
