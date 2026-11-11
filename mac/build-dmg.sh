#!/usr/bin/env bash
# Build a universal (Apple silicon + Intel) "Omarchy-Remote.dmg" into the given directory (default: mac/build).
set -euo pipefail
cd "$(dirname "$0")"
out="$(mkdir -p "${1:-build}" && cd "${1:-build}" && pwd)"
stage="$out/dmg"
rm -rf "$stage" "$out/Omarchy-Remote.dmg"
UNIVERSAL=1 ./build-app.sh "$stage"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Omarchy Remote" -srcfolder "$stage" -ov -format UDZO "$out/Omarchy-Remote.dmg"
rm -rf "$stage"
echo "$out/Omarchy-Remote.dmg"
