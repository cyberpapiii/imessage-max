#!/usr/bin/env bash
# Prints the Homebrew cask for one release of iMessage Max.
# Usage: generate-cask.sh <version> <sha256 of iMessage-Max-<version>.dmg>
#
# The upgrade path keeps the helper running: Homebrew skips `signal` on
# `brew upgrade` but always runs `launchctl`, and the companion that brew
# reopens restarts an outdated helper only if it is still running. So
# `uninstall` stops the helper with SIGUSR1, which makes it drain and exit 0,
# and KeepAlive does not restart a zero exit; only `zap` removes the launchd
# job. Not SIGTERM: with Keep running on, the helper exits 75 on SIGTERM and
# launchd would relaunch it from the app brew just deleted.
# Never give `uninstall` an on_upgrade list that includes signal:
# then `brew upgrade` would send USR1 and leave the helper stopped until
# the next login. Homebrew skips `signal` on upgrade only without it
# (cask/artifact/abstract_uninstall.rb, UPGRADE_REINSTALL_SKIP_DIRECTIVES).
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <version> <dmg sha256>" >&2
  exit 2
fi
VERSION="$1"
SHA256="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version '$VERSION' is not X.Y.Z" >&2; exit 2; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: '$SHA256' is not a sha256 digest" >&2; exit 2; }

APP="iMessage Max.app"
APP_ID="com.cyberpapiii.imessage-max.menubar"
AGENT_LABEL="com.cyberpapiii.imessage-max.helper"

cat <<CASK
cask "imessage-max" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/cyberpapiii/imessage-max/releases/download/v#{version}/iMessage-Max-#{version}.dmg"
  name "iMessage Max"
  desc "MCP server that lets AI assistants read, search and send iMessages"
  homepage "https://github.com/cyberpapiii/imessage-max"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "$APP"
  binary "#{appdir}/$APP/Contents/MacOS/imessage-max"

  uninstall quit:   "$APP_ID",
            signal: ["USR1", "$AGENT_LABEL"]

  zap launchctl: "$AGENT_LABEL",
      trash:     [
        "~/Library/Application Support/iMessage Max",
        "~/Library/Caches/$APP_ID",
        "~/Library/HTTPStorages/$APP_ID",
        "~/Library/Logs/iMessage Max",
        "~/Library/Logs/imessage-max.stderr.log",
        "~/Library/Logs/imessage-max.stdout.log",
        "~/Library/Preferences/$APP_ID.plist",
      ]
end
CASK
