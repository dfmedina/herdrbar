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

# If the login item (./login.sh on) is active, stop it via launchd so KeepAlive doesn't relaunch mid-copy.
LABEL=dev.local.herdrbar
DOMAIN=gui/$(id -u)
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then AGENT=1; launchctl bootout "$DOMAIN/$LABEL"; else AGENT=0; fi

mkdir -p ~/Applications
pkill -x HerdrBar 2>/dev/null || true
rm -rf ~/Applications/HerdrBar.app
cp -R "$APP" ~/Applications/

if (( AGENT )); then
    launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/$LABEL.plist
    echo "Installed and restarted ~/Applications/HerdrBar.app"
else
    echo "Installed ~/Applications/HerdrBar.app — run: open ~/Applications/HerdrBar.app"
fi
