#!/usr/bin/env bash
# Signs one path with hardened runtime, using script/signing_identity.sh.
# Usage: sign.sh <path> [extra codesign arguments...]
set -euo pipefail

TARGET="$1"
shift
IDENTITY="$("$(dirname "${BASH_SOURCE[0]}")/signing_identity.sh")"
# An ad hoc signature cannot carry a secure timestamp, and --timestamp needs
# the network, so it is passed only for a real identity.
TIMESTAMP="--timestamp"
if [ "$IDENTITY" = "-" ]; then
  TIMESTAMP=""
fi
codesign --force --options runtime ${TIMESTAMP:+"$TIMESTAMP"} "$@" --sign "$IDENTITY" "$TARGET"
echo "✓ Signed $TARGET with $IDENTITY"
