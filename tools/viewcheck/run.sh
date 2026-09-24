#!/bin/bash
# tools/viewcheck/run.sh <session id> [light|dark]
#
# Render the sessions window's panes, the script laid out flat, the sidebar
# rows, the picture viewer and Settings for one session, to PNGs in a new
# folder (printed at the end). Reads a backup of the development copy's
# catalog (CATALOG= to read another), never the catalog itself.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ID="${1:?usage: run.sh <session id> [light|dark]}"
MODE="${2:-light}"
CATALOG="${CATALOG:-$HOME/Library/Application Support/car-dev/car.sqlite}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/viewcheck.XXXXXX")"

# The app's sources, all but its main.swift, into Sources/viewcheck/app
# (not tracked), with the views the check reaches into opened up.
APP="$HERE/Sources/viewcheck/app"
rm -rf "$APP" && mkdir -p "$APP"
find "$HERE/../../App" -name '*.swift' ! -name 'main.swift' -exec cp {} "$APP/" \;
sed -i '' 's/^private struct/struct/' "$APP/ScriptView.swift" "$APP/Sidebar.swift"

mkdir -p "$WORK/root" "$WORK/out"
sqlite3 "$CATALOG" ".backup '$WORK/root/car.sqlite'"
swift build --package-path "$HERE" -q
CAR_ROOT="$WORK/root" "$HERE/.build/debug/viewcheck" "$WORK/out" "$ID" "$MODE"
echo "pictures in $WORK/out"
