#!/bin/bash
# build-dmg.sh — Creates a distributable DMG with a drag-to-Applications alias.
#
# Usage:
#   scripts/build-dmg.sh <path-to-KeySwap.app> <version>
#
# Example:
#   scripts/build-dmg.sh build/Release/KeySwap.app 1.2.2.0
#
# Output:
#   release/KeySwap-<version>.dmg

set -e

APP_PATH="$1"
VERSION="$2"

if [ -z "$APP_PATH" ] || [ -z "$VERSION" ]; then
    echo "Usage: $0 <path-to-KeySwap.app> <version>"
    echo "Example: $0 build/Release/KeySwap.app 1.2.2.0"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at '$APP_PATH'"
    exit 1
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

mkdir -p release

cp -r "$APP_PATH" "$STAGING/KeySwap.app"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="release/KeySwap-${VERSION}.dmg"

echo "Building $DMG_PATH ..."
hdiutil create \
    -volname "KeySwap ${VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Done: $DMG_PATH"
