#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="iMessage Max"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INSTALL_BUNDLE="$HOME/Applications/$APP_NAME.app"
case "$MODE" in
  run|--verify|--build-only|--install|--logs|--telemetry|--debug) ;;
  *) echo "usage: $0 [--verify|--build-only|--install|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac

pkill -x iMessageMaxMenu >/dev/null 2>&1 || true
"$ROOT_DIR/script/assemble_app.sh" "$APP_BUNDLE" release
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"

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
  # Remove, then copy. Writing over the running helper's file makes macOS
  # kill it; a new file leaves it running until the app restarts it.
  rm -rf "$INSTALL_BUNDLE"
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
