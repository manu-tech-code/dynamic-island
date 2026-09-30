#!/bin/zsh
# Generates the Xcode project, builds Debug, and relaunches the app.
#   scripts/run.sh            build and launch
#   scripts/run.sh --no-run   build only
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
DERIVED="$ROOT/build/DerivedData"

xcodegen generate --quiet
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Debug \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' build -quiet 2>&1 \
  | grep -vE "^(Command line invocation|Build settings from|    [A-Z_]+ = )" || true

APP="$DERIVED/Build/Products/Debug/DynamicIsland.app"
[[ -d "$APP" ]] || { echo "build failed: $APP missing"; exit 1; }
echo "built $APP"

if [[ "${1:-}" != "--no-run" ]]; then
  pkill -x DynamicIsland 2>/dev/null && sleep 0.5 || true
  open "$APP"
  echo "launched"
fi
