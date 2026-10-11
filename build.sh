#!/bin/zsh
# Builds Vox.app (release, size-optimized), signs it, and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
./test.sh || { echo "Command tests failed; not installing."; exit 1; }
swift build -c release --arch arm64
APP=build/Vox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Icon/AppIcon.icns ] || swift Icon/make-icon.swift Icon
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Vox "$APP/Contents/MacOS/Vox"
cp Info.plist "$APP/Contents/Info.plist"
# A fixed designated requirement keeps macOS permissions (Accessibility, Microphone) across rebuilds;
# plain ad-hoc signing ties them to the binary hash, which changes every build.
codesign --force --sign - --identifier local.vox.assistant -r='designated => identifier "local.vox.assistant"' "$APP"
pkill -x Vox || true
rm -rf /Applications/Vox.app
ditto "$APP" /Applications/Vox.app
rm -rf build
touch /Applications/Vox.app   # refresh the Finder/Dock icon cache
echo "Installed /Applications/Vox.app"

# ./build.sh --dmg also makes a drag-to-install disk image in dist/.
if [[ "${1:-}" == "--dmg" ]]; then
    mkdir -p dist
    STAGE=$(mktemp -d)
    ditto /Applications/Vox.app "$STAGE/Vox.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f dist/Vox.dmg
    hdiutil create -volname "Vox" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet dist/Vox.dmg
    rm -rf "$STAGE"
    echo "Created dist/Vox.dmg"
fi
