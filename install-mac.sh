#!/usr/bin/env bash
# curl -fsSL https://raw.githubusercontent.com/thesnarkitecht/omarchy-remote-desktop/main/install-mac.sh | bash
# Builds Omarchy Remote.app from source (needs Xcode Command Line Tools) into ~/Applications.
set -euo pipefail
ref="${OMARCHY_REMOTE_REF:-main}"
[[ $(uname) == Darwin ]] || { echo "This installer is for macOS. On Omarchy use install.sh."; exit 1; }
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  echo "Install the Command Line Tools from the dialog, then run this again."
  exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/thesnarkitecht/omarchy-remote-desktop/archive/$ref.tar.gz" | tar xz -C "$tmp" --strip-components=1
"$tmp/mac/build-app.sh" "$tmp/out"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Omarchy Remote.app"
mv "$tmp/out/Omarchy Remote.app" "$HOME/Applications/"
echo "Installed ~/Applications/Omarchy Remote.app"
open "$HOME/Applications/Omarchy Remote.app"
