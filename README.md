# HerdrBar

Touch Bar control panel for [herdr](https://herdr.dev). See `PLAN.md`.

## Build / run

```sh
./build.sh                      # compiles, ad-hoc signs, installs to ~/Applications
open ~/Applications/HerdrBar.app
```

Needs only the Command Line Tools (`swiftc`), no Xcode.

## Stop

```sh
pkill -x HerdrBar
```

Logs: `log stream --predicate 'process == "HerdrBar"'`

## Remove

Delete `~/Applications/HerdrBar.app` and this folder (plus the LaunchAgent plist, if one was added later).
