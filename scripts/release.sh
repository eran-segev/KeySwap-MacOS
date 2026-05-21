#!/bin/bash
# release.sh — Bumps all version fields and prepares for a DMG release.
#
# Usage:
#   scripts/release.sh <version> <build-number>
#
# Example:
#   scripts/release.sh 1.2.2.0 7
#
# What this script does:
#   1. Updates VERSION file
#   2. Updates CFBundleShortVersionString in KeySwap/Info.plist
#   3. Updates CFBundleVersion (build number) in KeySwap/Info.plist
#   4. Prints instructions to build in Xcode and create the DMG
#
# What this script does NOT do (requires Xcode keychain + signing):
#   - Build the app (do this in Xcode: Product > Archive, then Export)
#   - Create the DMG (run scripts/build-dmg.sh after building)

set -e

NEW_VERSION="$1"
BUILD_NUMBER="$2"
PLISTBUDDY="/usr/libexec/PlistBuddy"
INFO_PLIST="KeySwap/Info.plist"

if [ -z "$NEW_VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
    echo "Usage: $0 <version> <build-number>"
    echo "Example: $0 1.2.2.0 7"
    exit 1
fi

if [ ! -x "$PLISTBUDDY" ]; then
    echo "Error: PlistBuddy not found at $PLISTBUDDY"
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "Error: $INFO_PLIST not found. Run this script from the repo root."
    exit 1
fi

echo "Bumping version to $NEW_VERSION (build $BUILD_NUMBER) ..."

echo "$NEW_VERSION" > VERSION

"$PLISTBUDDY" -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"
"$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"

echo ""
echo "Version fields updated:"
echo "  VERSION                    -> $NEW_VERSION"
echo "  CFBundleShortVersionString -> $NEW_VERSION"
echo "  CFBundleVersion            -> $BUILD_NUMBER"
echo ""
echo "Next steps:"
echo "  1. Build in Xcode: Product > Archive, then Export (Release config)"
echo "     Default derived-data path:"
echo "       ~/Library/Developer/Xcode/DerivedData/KeySwap-*/Build/Products/Release/KeySwap.app"
echo "     Or find it with: xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR"
echo ""
echo "  2. Create the DMG:"
echo "       scripts/build-dmg.sh <path-to-KeySwap.app> $NEW_VERSION"
echo ""
echo "  3. Test the DMG:"
echo "       - About window shows Version $NEW_VERSION"
echo "       - DMG contains KeySwap.app + Applications shortcut"
echo "       - Launch second instance -> 'KeySwap is already running' alert appears"
echo ""
echo "  4. Commit and tag:"
echo "       git add -A && git commit -m 'chore: bump version to $NEW_VERSION'"
echo "       git tag v$NEW_VERSION"
