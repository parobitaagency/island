#!/usr/bin/env bash
# Builds build/Island.app (ad-hoc signed) and dist/Island.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --product Island
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/Island.app"
rm -rf "$APP" dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp "$BIN/Island" "$APP/Contents/MacOS/Island"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --sign - --identifier com.parobita.island "$APP"
codesign --verify --strict --verbose=2 "$APP"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Island" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet dist/Island.dmg
echo "built $APP and dist/Island.dmg"
