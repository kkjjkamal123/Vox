#!/bin/zsh
# Builds Vox.app (release, size-optimized), signs it, and installs it to /Applications.
#
#   ./build.sh                 tests, builds, signs and installs to /Applications
#   ./build.sh --dmg           same, plus dist/Vox.dmg
#   ./build.sh --no-install    tests, builds and signs into build/Vox.app only (nothing is quit or replaced)
#   ./build.sh --out DIR       with --no-install: put the signed Vox.app in DIR instead of build/
#   ./build.sh --dev           also compiles the developer modes (--exec, --listen-test, VOX_LOG …), which can
#                              use Vox's microphone and Accessibility permissions; never ship a --dev build
set -euo pipefail
cd "$(dirname "$0")"

dmg=0; install=1; dev=0; out=""
while (( $# )); do
    case "$1" in
        --dmg) dmg=1 ;;
        --no-install) install=0 ;;
        --dev) dev=1 ;;
        --out) shift; out="${1:?--out needs a directory}" ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

./test.sh || { echo "Command tests failed; not installing."; exit 1; }
flags=()
(( dev )) && flags=(-Xswiftc -DVOX_DEV)
swift build -c release --arch arm64 "${flags[@]}"
BIN=$(swift build -c release --arch arm64 "${flags[@]}" --show-bin-path)
APP=build/Vox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Icon/AppIcon.icns ] || swift Icon/make-icon.swift Icon
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/Vox" "$APP/Contents/MacOS/Vox"
cp Info.plist "$APP/Contents/Info.plist"
# A fixed designated requirement keeps macOS permissions (Accessibility, Microphone) across rebuilds;
# plain ad-hoc signing ties them to the binary hash, which changes every build.
codesign --force --sign - --identifier local.vox.assistant -r='designated => identifier "local.vox.assistant"' "$APP"
codesign --verify --strict "$APP"

if (( ! install )); then
    if [[ -n "$out" ]]; then
        mkdir -p "$out"
        rm -rf "$out/Vox.app"
        ditto "$APP" "$out/Vox.app"
        rm -rf build
        APP="$out/Vox.app"
    fi
    echo "Built $APP (not installed)"
else
    pkill -x Vox || true
    rm -rf /Applications/Vox.app
    ditto "$APP" /Applications/Vox.app
    rm -rf build
    touch /Applications/Vox.app   # refresh the Finder/Dock icon cache
    APP=/Applications/Vox.app
    echo "Installed /Applications/Vox.app"
fi

# --dmg also makes a drag-to-install disk image in dist/.
if (( dmg )); then
    mkdir -p dist
    STAGE=$(mktemp -d)
    ditto "$APP" "$STAGE/Vox.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f dist/Vox.dmg
    hdiutil create -volname "Vox" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet dist/Vox.dmg
    rm -rf "$STAGE"
    echo "Created dist/Vox.dmg"
fi
