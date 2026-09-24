#!/bin/bash
# Build CarDrive (tools/drive.swift), the live-test driver, and with a host,
# put it and the dev copy of car on that Mac and start car-dev there.
#
#   tools/drive.sh              build tools/.build/CarDrive.app
#   tools/drive.sh HOST         and install it and /Applications/car-dev.app
#                               (run ./build.sh first) on HOST over ssh
#
# HOST must be a Mac with someone logged in and no one using it: CarDrive's
# plans are real mouse and keyboard input. Both apps need their grants on
# that Mac, given once by a person (Screen Sharing is enough): car-dev
# Accessibility, Microphone and Screen Recording; CarDrive Accessibility and
# Screen Recording.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/tools/.build/CarDrive.app"
HOST="${1:-}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
xcrun swiftc -O -target arm64-apple-macos26.0 -o "$OUT/Contents/MacOS/CarDrive" "$HERE/tools/drive.swift"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.car.drive</string>
  <key>CFBundleName</key><string>CarDrive</string>
  <key>CFBundleExecutable</key><string>CarDrive</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}' || true)"
codesign --force --options runtime --sign "${IDENTITY:--}" "$OUT"
echo "==> built $OUT"
[ -n "$HOST" ] || exit 0

DEV="/Applications/car-dev.app"
[ -d "$DEV" ] || { echo "no $DEV here; run ./build.sh first" >&2; exit 1; }
# Quit car-dev there by its exact command line (the app, never a car-dev
# command someone is running), then replace both apps and start car-dev.
ssh "$HOST" 'pid=$(pgrep -f "^/Applications/car-dev.app/Contents/MacOS/car-dev$" || true)
    if [ -n "$pid" ]; then kill -TERM $pid; for _ in $(seq 1 50); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done; fi'
/opt/homebrew/bin/rsync -a --delete "$DEV/" "${HOST}:/Applications/car-dev.app/"
/opt/homebrew/bin/rsync -a --delete "$OUT/" "${HOST}:/Applications/CarDrive.app/"
ssh "$HOST" 'mkdir -p ~/.local/bin && ln -sf /Applications/car-dev.app/Contents/MacOS/car-dev ~/.local/bin/car-dev && open /Applications/car-dev.app'
echo "==> car-dev and CarDrive are on $HOST; car-dev is running there"
