#!/bin/bash
# Build script for imessage-max with embedded Info.plist
# This creates a properly signed binary with stable bundle identifier

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
BUNDLE_ID="com.cyberpapiii.imessage-max"
INFO_PLIST="$SCRIPT_DIR/Sources/Resources/Info.plist"
BUILD_DIR="$SCRIPT_DIR/.build/release"
BINARY="$BUILD_DIR/imessage-max"

echo "Building imessage-max..."

# Build with linker flags using absolute path
swift build -c release \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker "$INFO_PLIST"

echo "Build complete: $BINARY"

# Re-sign to bind the Info.plist
echo ""
echo "Re-signing binary to bind Info.plist..."
codesign --force --sign - --identifier "$BUNDLE_ID" "$BINARY"

# Verify Info.plist is embedded
echo ""
echo "Verifying embedded Info.plist..."
if otool -s __TEXT __info_plist "$BINARY" | grep -q "Contents"; then
    echo "Info.plist embedded successfully"

    # Show the embedded plist
    echo ""
    echo "Embedded Info.plist contents:"
    otool -s __TEXT __info_plist "$BINARY" | tail -n +3 | xxd -r -p | plutil -p - 2>/dev/null || echo "(Could not parse plist)"
else
    echo "WARNING: Info.plist may not be embedded correctly"
fi

# Check code signature
echo ""
echo "Code signature info:"
codesign -dvvv "$BINARY" 2>&1 | grep -E "(Identifier|Info.plist|TeamIdentifier)" || true

echo ""
echo "Binary ready at: $BINARY"
echo ""
echo "To install:"
echo "  cp $BINARY /usr/local/bin/imessage-max"
echo ""
echo "Or update Homebrew formula to use this build script."
