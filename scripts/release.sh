#!/bin/zsh
# Builds a Release copy and packages it as a .dmg with an Applications link.
#   scripts/release.sh            build build/DynamicIsland-<version>.dmg
#   scripts/release.sh --upload   also attach it to the GitHub release v<version>
#                                 (run from release/<version>, after the Release workflow)
# The app is signed with your Apple Development certificate: it runs on your
# own Macs. Sharing it with other people needs a Developer ID certificate and
# notarization (Apple Developer Program).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
DERIVED="$ROOT/build/DerivedData"
VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)
UPLOAD=false
[[ "${1:-}" == "--upload" ]] && UPLOAD=true

if $UPLOAD; then
  git fetch --quiet --tags origin
  TAG_COMMIT=$(git rev-parse -q --verify "v$VERSION^{commit}") \
    || { echo "no tag v$VERSION yet: merge develop into main first"; exit 1; }
  [[ "$(git rev-parse HEAD)" == "$TAG_COMMIT" ]] \
    || { echo "HEAD isn't v$VERSION: git switch release/$VERSION && git pull"; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "uncommitted changes: commit or stash them first"; exit 1; }
fi

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

if $UPLOAD; then
  gh release upload "v$VERSION" "$DMG" --clobber
  echo "attached to $(gh release view "v$VERSION" --json url --jq .url)"
fi
