#!/usr/bin/env bash
# Packs the Claude Desktop extension iMessage-Max-<version>.mcpb from
# mcpb/manifest.json, its icons, and an already signed imessage-max binary,
# then checks the bundle it wrote.
#
# Claude Desktop runs server/imessage-max with no arguments, which is the
# stdio bridge to the iMessage Max helper. The bundle therefore needs no path
# prompt, and Claude needs no Full Disk Access of its own.
#
# Usage: build-mcpb.sh <signed imessage-max binary> <output dir>
#
# The binary is copied byte for byte, so it keeps the signature it has.
# Prints the bundle's path on the last line.
set -euo pipefail

MCPB_CLI="@anthropic-ai/mcpb@2.1.2"
EXPECTED_LAYOUT="assets/icon-128.png
assets/icon-16.png
assets/icon-256.png
assets/icon-32.png
assets/icon-512.png
assets/icon-64.png
manifest.json
server/imessage-max"

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <signed imessage-max binary> <output dir>" >&2
  exit 2
fi
BINARY="$1"
OUT_DIR="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "error: $*" >&2; exit 1; }

[[ -x "$BINARY" ]] || fail "$BINARY is not an executable file"
codesign --verify --strict "$BINARY" || fail "$BINARY is not validly signed"
VERSION="$("$ROOT_DIR/scripts/check-version.sh" --print)"
MANIFEST_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT_DIR/mcpb/manifest.json")"
[[ "$MANIFEST_VERSION" == "$VERSION" ]] || fail "mcpb/manifest.json is $MANIFEST_VERSION, Version.swift is $VERSION"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE/server" "$OUT_DIR"
cp "$ROOT_DIR/mcpb/manifest.json" "$STAGE/manifest.json"
cp -R "$ROOT_DIR/mcpb/assets" "$STAGE/assets"
cp "$BINARY" "$STAGE/server/imessage-max"
chmod 755 "$STAGE/server/imessage-max"

BUNDLE="$OUT_DIR/iMessage-Max-$VERSION.mcpb"
rm -f "$BUNDLE"
npx --yes "$MCPB_CLI" validate "$STAGE/manifest.json"
npx --yes "$MCPB_CLI" pack "$STAGE" "$BUNDLE"

echo "==> Checking $BUNDLE"
LAYOUT="$(unzip -Z1 "$BUNDLE" | grep -v '/$' | LC_ALL=C sort)"
[[ "$LAYOUT" == "$EXPECTED_LAYOUT" ]] || fail "unexpected layout:"$'\n'"$LAYOUT"
UNPACKED="$WORK_DIR/unpacked"
unzip -q "$BUNDLE" -d "$UNPACKED"
INNER="$UNPACKED/server/imessage-max"
[[ -x "$INNER" ]] || fail "server/imessage-max lost its executable bit"
cmp -s "$BINARY" "$INNER" || fail "server/imessage-max differs from $BINARY"
codesign --verify --strict "$INNER" || fail "server/imessage-max fails codesign --verify"
[[ "$("$INNER" --version)" == *"$VERSION"* ]] || fail "server/imessage-max does not report $VERSION"
COMMAND="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"]["mcp_config"]["command"])' "$UNPACKED/manifest.json")"
[[ "$COMMAND" == "\${__dirname}/server/imessage-max" ]] || fail "manifest command is $COMMAND"
echo "$LAYOUT"
echo "$BUNDLE"
