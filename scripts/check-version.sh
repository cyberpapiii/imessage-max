#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift_v=$(sed -nE 's/^ *static let current = "([^"]+)"/\1/p' swift/Sources/iMessageMax/Server/Version.swift)
if [[ "${1:-}" == "--print" ]]; then
  [[ -n "$swift_v" ]] || { echo "No version found in Version.swift" >&2; exit 1; }
  echo "$swift_v"
  exit 0
fi
plist_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' swift/Sources/Resources/Info.plist)
plist_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' swift/Sources/Resources/Info.plist)
mcpb_v=$(python3 -c 'import json,sys;print(json.load(open("mcpb/manifest.json"))["version"])')
codex_v=$(python3 -c 'import json,sys;print(json.load(open(".codex-plugin/plugin.json"))["version"])')

status=0
for pair in "Info.plist short:$plist_short" "Info.plist build:$plist_build" "mcpb/manifest.json:$mcpb_v" ".codex-plugin/plugin.json:$codex_v"; do
  name=${pair%%:*}; v=${pair##*:}
  if [[ "$v" != "$swift_v" ]]; then
    echo "MISMATCH $name = $v (Version.swift = $swift_v)" >&2
    status=1
  fi
done

floor=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' swift/Sources/Resources/Info.plist)
if [[ "$floor" != "15.0" ]]; then
  echo "MISMATCH Info.plist LSMinimumSystemVersion = $floor (expected 15.0)" >&2
  status=1
fi

if [[ "${1:-}" == "--tag" ]]; then
  tag=$(git describe --tags --exact-match 2>/dev/null || true)
  if [[ "$tag" != "v$swift_v" ]]; then
    echo "TAG MISMATCH HEAD tag '$tag' != v$swift_v" >&2
    status=1
  fi
fi

[[ $status -eq 0 ]] && echo "OK $swift_v"
exit $status
