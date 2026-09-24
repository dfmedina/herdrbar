#!/bin/zsh
# Start HerdrBar at login (and restart it if it crashes) via a LaunchAgent.
#   ./login.sh on    install + start
#   ./login.sh off   stop + remove
set -euo pipefail

LABEL=dev.local.herdrbar
PLIST=~/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)

case "${1:-}" in
on)
    mkdir -p ~/Library/LaunchAgents
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$HOME/Applications/HerdrBar.app/Contents/MacOS/HerdrBar</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    pkill -x HerdrBar 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "HerdrBar will start at login (and is running now)."
    ;;
off)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed login item; HerdrBar stopped."
    ;;
*)
    echo "usage: $0 on|off" >&2
    exit 1
    ;;
esac
