# HerdrBar — plan

A small self-built macOS app that turns the Touch Bar into a control panel for
[herdr](https://herdr.dev): one button per herdr tab, showing live agent status;
tap a button to jump to that tab.

Build phase by phase. Test each phase with the user before moving on.

## Context (verified 2026-09-23)

- Mac: MacBook Pro 13" M1 (MacBookPro17,1), macOS 26.6.2, arm64.
- Touch Bar is set to show **App Controls + Control Strip** (`com.apple.touchbar.agent PresentationModeGlobal = appWithControlStrip`).
  Changed from function keys on 2026-09-23: function-keys mode hides the system-modal bar unless `fn` is held.
- Toolchain: `swiftc` 6.1.2 (Command Line Tools, no Xcode). Build with `swiftc` only.
- herdr 0.9.1 at `~/.local/bin/herdr` (on PATH in terminals, NOT in GUI apps — always use the absolute path).
  Runs as a TUI inside Ghostty 1.3.1. Socket: `~/.config/herdr/herdr.sock`.
- User runs Claude Code and opencode as agents inside herdr tabs.
- The user has a Claude **Pro plan**: keep sessions lean (few, purposeful tool calls).
- User wants **free tools only**. Rejected: BetterTouchTool (paid), MTMR (unnotarized,
  Intel-only, Gatekeeper warning). Both fully uninstalled.

### herdr CLI (all output JSON)

```
herdr workspace list   -> result.workspaces[]: workspace_id, label, focused, agent_status
herdr tab list         -> result.tabs[]: tab_id ("w1:t2"), workspace_id, number, label, focused, agent_status, pane_count
herdr tab focus <tab_id>
```
Errors look like `{"id":..., "error":{"code":"server_not_running", ...}}`.
agent_status values: `working`, `blocked` (needs user), `done` (finished, unseen), `idle`, `unknown` (no agent).
Real example tabs: `CC` (claude), `Opencode` (opencode), `version control` (no agent).

### Existing helper (keep; reference implementation)

`~/.local/bin/herdr-tb` (Python): `list`, `label N`, `focus N`. Shows tabs of the focused
workspace sorted by `number`; icons ⏳ working · 🔴 blocked · ✅ done · ⚪ idle · none for unknown;
`focus` runs `herdr tab focus <id>` then `open -a Ghostty`. Tested and working.

### Private Touch Bar APIs (verified present on this Mac via runtime check)

- `NSTouchBar` class methods (respond: true):
  `presentSystemModalTouchBar:systemTrayItemIdentifier:`,
  `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:`,
  `dismissSystemModalTouchBar:`, `minimizeSystemModalTouchBar:`
  (`presentSystemModalFunctionBar:systemTrayItemIdentifier:` does NOT exist.)
- DFRFoundation exports (load via `dlopen`/`dlsym` from
  `/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation`):
  `DFRElementSetControlStripPresenceForIdentifier`,
  `DFRElementGetControlStripPresenceForIdentifier`,
  `DFRSystemModalShowsCloseBoxWhenFrontMost`.
- Call the NSTouchBar class methods via selectors (`perform`/`@objc` declarations), since they are not in the public SDK.
- Also add the tray item with `NSTouchBarItem.addSystemTrayItem:` (private; check with `responds(to:)` first).
- MTMR (open source, github.com/Toxblh/MTMR) uses this same approach — a useful reference if stuck.

## Design (decisions agreed with the user)

- One button per herdr **tab** of the focused workspace, label = `<icon> <tab label>`.
- Status as **icons** (not colored backgrounds). Highlight the focused tab.
- Button count follows the tab count (no empty slots).
- **Control Strip icon** (right-hand system area) brings the tab buttons back; the system ✕ hides them.
- Refresh every **1 s** by running `herdr workspace list` + `herdr tab list` from Swift (`Process`).
- Tap → `herdr tab focus <tab_id>`, then bring Ghostty to front (`NSWorkspace` / `open -a Ghostty`).
- herdr not running → single "herdr off" button; tap opens Ghostty.
- Background app: `LSUIElement = true` (no Dock icon, no menu bar). No special permissions needed.

## Files

```
~/freelance/herdrbar/
├── PLAN.md              # this file
├── Sources/main.swift   # the whole app (~150–200 lines)
├── Info.plist           # LSUIElement, bundle id e.g. dev.local.herdrbar
├── build.sh             # swiftc -> HerdrBar.app, ad-hoc sign (codesign -s -), copy to ~/Applications
└── README.md            # build / run / remove
```

## Phases

1. **Prototype** — show 2 fixed buttons on the Touch Bar + Control Strip icon.
   Proves the private APIs work here, including on top of function-keys mode.
   If it can't work, stop here and tell the user.
   **Done 2026-09-23.** Works via `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` with placement 0
   (called through its IMP, since placement is a non-object arg). Placement 1 would hide the Control Strip.
   The 🐑 tray icon only shows while the bar is hidden: the system ✕ (close box) hides it, 🐑 brings it back.
   Logging goes to `~/Library/Logs/HerdrBar.log` (NSLog lines don't show up in `log show`).
2. **Live herdr data** — real tabs and statuses, refreshed every second.
   **Done 2026-09-23.** Status changes update titles in place; tab add/remove rebuilds `defaultItemIdentifiers`
   on the presented bar (no re-present needed). NSTouchBar reuses items across layout changes, so buttons are
   looked up with `bar.item(forIdentifier:)` each refresh, never cached. ~0.2% CPU.
3. **Tapping** — focus the herdr tab + bring Ghostty forward.
   **Done 2026-09-23.** `herdr tab focus` off the main thread, then `NSWorkspace.openApplication` for
   `com.mitchellh.ghostty`, then an immediate refresh. No noticeable delay.
4. **Polish** — focused-tab highlight, "herdr off" state, button styling.
   **Done 2026-09-23.** Focused tab: `bezelColor = .controlAccentColor`. Names capped at 16 chars with "…".
   "herdr off" is a button that opens Ghostty — not yet tested (quitting herdr would kill the Claude session running in it).
5. **Start at login (optional, ask first)** — LaunchAgent in `~/Library/LaunchAgents`; README explains removal.

Later (not v1): instant updates via herdr `events.subscribe` (`pane.agent_status_changed`);
long-press actions (jump to blocked agent, new tab).

## Risks

- Private APIs could break in a future macOS update → the app simply stops showing buttons.
- Function-keys mode might hide system-modal bars → check in phase 1; if so, the user changes
  that one Touch Bar setting.
- Touch Bar flickers in dim light (OLED hardware wear; not software). A lamp helps; unrelated to this app.

## Removal

Delete `~/Applications/HerdrBar.app`, this folder, and the LaunchAgent plist if added.
