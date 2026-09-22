#!/bin/bash
# Build, sign and install owl to /Applications, and put the `owl` command on
# the path.
#
#   ./build.sh
#
# The app is installed at a fixed path and signed with a stable identity on
# purpose: macOS keys the Accessibility, Microphone, Screen Recording and
# Automation grants to bundle id + signing identity + path, and a path that
# changes every build loses them.
#
# Signing: the first "Apple Development" identity in the keychain, with the
# team read off its certificate, so nothing about an account is written here.
# With no such identity the build signs ad hoc, which works for a local run
# but re-prompts for every grant after each rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/owl.app"
export PATH="/opt/homebrew/bin:$PATH"

IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}' || true)"
TEAM=""
if [ -n "$IDENTITY" ]; then
    TEAM="$(security find-certificate -c "Apple Development" -p \
        | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]+).*/\1/')"
fi

cd "$HERE"
[ -d owl/Assets.xcassets ] || swift tools/make-icon.swift
xcodegen >/dev/null

echo "==> building"
if [ -n "$IDENTITY" ]; then
    xcodebuild -project owl.xcodeproj -scheme owl -configuration Release \
        -derivedDataPath "$HERE/.build" \
        CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$TEAM" build 2>&1 | grep -E 'error:|warning: unre|BUILD' | tail -20
else
    xcodebuild -project owl.xcodeproj -scheme owl -configuration Release \
        -derivedDataPath "$HERE/.build" \
        CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
        build 2>&1 | grep -E 'error:|BUILD' | tail -20
fi
BUILT="$HERE/.build/Build/Products/Release/owl.app"
[ -d "$BUILT" ] || { echo "build produced no app"; exit 1; }

if pgrep -x owl >/dev/null; then
    echo "==> stopping the running copy"
    pkill -x owl || true
    sleep 1
fi
rm -rf "$APP"
cp -R "$BUILT" "$APP"

SIGN="${IDENTITY:--}"
echo "==> signing $APP as $SIGN"
codesign --force --deep --options runtime \
    --entitlements "$HERE/owl/owl.entitlements" --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/owl" "$HOME/.local/bin/owl"
echo "==> installed $APP; the owl command is $HOME/.local/bin/owl"
open "$APP"
