#!/bin/zsh
# Builds a Release copy and packages it as a .dmg with an Applications link.
#   scripts/release.sh
# The app is signed with your Apple Development certificate: it runs on your
# own Macs. Sharing it with other people needs a Developer ID certificate and
# notarization (Apple Developer Program).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
DERIVED="$ROOT/build/DerivedData"
VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)

xcodegen generate --quiet
(cd Packages/IslandKit && swift test 2>&1 | grep -E "Test run|✘")
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build -quiet 2>&1 \
  | grep -vE "appintentsmetadataprocessor" || true

APP="$DERIVED/Build/Products/Release/DynamicIsland.app"
[[ -d "$APP" ]] || { echo "release build failed"; exit 1; }
codesign --verify --deep --strict "$APP"
echo "signed: $(codesign -dvv "$APP" 2>&1 | awk -F= '/Authority/ {print $2; exit}')"

STAGE="$ROOT/build/dmg"
DMG="$ROOT/build/DynamicIsland-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Dynamic Island.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Dynamic Island $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
