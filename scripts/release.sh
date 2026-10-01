#!/bin/zsh
# Builds a Release copy, packages it as a .dmg with an Applications link, signs
# the .dmg for Sparkle and writes the appcast that installed copies read.
#   scripts/release.sh            build build/DynamicIsland-<version>.dmg and build/appcast.xml
#   scripts/release.sh --upload   also attach both to the draft GitHub release v<version>
#                                 and publish it (run from release/<version>, after the
#                                 Release workflow; published releases are immutable)
# Sparkle's update key lives in the login Keychain (account com.dynamicisland.mac);
# its public half is SUPublicEDKey in project.yml.
# The app is signed with your Apple Development certificate: it runs on your
# own Macs. Sharing it with other people needs a Developer ID certificate and
# notarization (Apple Developer Program).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
DERIVED="$ROOT/build/DerivedData"
VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)
BUILD=$(awk -F'"' '/CFBundleVersion:/ {print $2; exit}' project.yml)
REPO_URL="https://github.com/manu-tech-code/dynamic-island"
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

# Sparkle: the EdDSA signature of the .dmg, and an appcast describing this
# release. Installed copies read it from the latest release on GitHub.
SIGN_UPDATE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
SIGNATURE=$("$SIGN_UPDATE" --account com.dynamicisland.mac "$DMG")   # sparkle:edSignature="…" length="…"
APPCAST="$ROOT/build/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dynamic Island</title>
    <link>$REPO_URL</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/DynamicIsland-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "appcast $APPCAST (build $BUILD)"

if $UPLOAD; then
  [[ "$(gh release view "v$VERSION" --json isDraft --jq .isDraft)" == "true" ]] \
    || { echo "v$VERSION is already published (immutable): assets can only be added to a draft"; exit 1; }
  gh release upload "v$VERSION" "$DMG" "$APPCAST" --clobber
  gh release edit "v$VERSION" --draft=false --latest >/dev/null
  echo "published $(gh release view "v$VERSION" --json url --jq .url)"
fi
