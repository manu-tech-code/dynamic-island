#!/bin/zsh
# Builds the spikes and wraps each one in a signed .app under Spikes/build/.
# Signing with the same Apple Development identity every time keeps macOS
# permissions (Automation, paste access) from resetting between builds.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
OUT="$ROOT/build"
IDENTITY="${SPIKE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
PREFIX="com.dynamicisland.spike"

swift build -c release 2>&1 | grep -v "^\[" || true
BIN="$(swift build -c release --show-bin-path)"
[[ -x "$BIN/NotchGlassSpike" ]] || { echo "build failed"; exit 1; }
mkdir -p "$OUT"

make_app() {
  local name="$1" id="$2" extra="$3"
  local app="$OUT/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN/$name" "$app/Contents/MacOS/$name"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$PREFIX.$id</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrefersDisplaySafeAreaCompatibilityMode</key><false/>
  $extra
</dict></plist>
PLIST
}

make_app NotchGlassSpike notchglass ""
make_app ClipboardSpike clipboard ""
make_app NowPlayingSpike nowplaying "<key>NSAppleEventsUsageDescription</key><string>Reads the current track from Music or Spotify for the Now Playing spike.</string>"
cp "$BIN/libNowPlayingBridge.dylib" "$OUT/NowPlayingSpike.app/Contents/Resources/"
cp "$ROOT/Resources/np.pl" "$OUT/NowPlayingSpike.app/Contents/Resources/"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$OUT/NowPlayingSpike.app/Contents/Resources/libNowPlayingBridge.dylib"
  for a in NotchGlassSpike ClipboardSpike NowPlayingSpike; do
    codesign --force --timestamp=none --sign "$IDENTITY" "$OUT/$a.app"
  done
  echo "signed with $IDENTITY"
else
  echo "no Apple Development identity found; apps are unsigned (ad hoc)"
  for a in NotchGlassSpike ClipboardSpike NowPlayingSpike; do codesign --force --sign - "$OUT/$a.app"; done
fi
ls -1 "$OUT"
