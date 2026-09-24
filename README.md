# HerdrBar

Touch Bar control panel for [herdr](https://herdr.dev): one button per herdr tab (focused workspace)
with live agent status — ⏳ working · 🔴 blocked · ✅ done · ⚪ idle — and the focused tab highlighted.
Tap a button to jump to that tab in Ghostty. See `PLAN.md` for design and notes.

Needs Touch Bar set to **App Controls** with **Show Control Strip** on
(System Settings → Keyboard → Touch Bar Settings…). The system ✕ hides the buttons; the 🐑 in the
Control Strip brings them back.

## Build / run

```sh
./build.sh                      # compiles, ad-hoc signs, installs to ~/Applications (restarts it if running at login)
open ~/Applications/HerdrBar.app
```

Needs only the Command Line Tools (`swiftc`), no Xcode.

## Start at login

```sh
./login.sh on     # LaunchAgent ~/Library/LaunchAgents/dev.local.herdrbar.plist; also restarts it after a crash
./login.sh off    # stop and remove the LaunchAgent
```

## Stop

With the login item on, `pkill` won't stick (launchd restarts it) — use `./login.sh off`.
Otherwise: `pkill -x HerdrBar`.

Log: `~/Library/Logs/HerdrBar.log`

## Remove

```sh
./login.sh off
rm -rf ~/Applications/HerdrBar.app ~/Library/Logs/HerdrBar.log
```

Then delete this folder.
