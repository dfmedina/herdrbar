#!/bin/zsh
# Build HerdrBar.app with swiftc, ad-hoc sign it, install to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

APP=build/HerdrBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -target arm64-apple-macos12 -framework AppKit Sources/main.swift -o "$APP/Contents/MacOS/HerdrBar"
codesign --force -s - "$APP"

mkdir -p ~/Applications
pkill -x HerdrBar 2>/dev/null || true
rm -rf ~/Applications/HerdrBar.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/HerdrBar.app — run: open ~/Applications/HerdrBar.app"
