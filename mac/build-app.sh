#!/usr/bin/env bash
# Build "Omarchy Remote.app" into the given directory (default: mac/build).
set -euo pipefail
cd "$(dirname "$0")"
out="$(mkdir -p "${1:-build}" && cd "${1:-build}" && pwd)"
args=(-c release)
[[ -z ${UNIVERSAL:-} ]] || args+=(--arch arm64 --arch x86_64)
swift build "${args[@]}" --product OmarchyRemote
app="$out/Omarchy Remote.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build "${args[@]}" --show-bin-path)/OmarchyRemote" "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "$app"
