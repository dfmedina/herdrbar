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
├── login.sh             # on|off: LaunchAgent to start at login
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
   **Done 2026-09-23.** `./login.sh on|off`; KeepAlive restarts on crash (tested with `kill -9`).
   `build.sh` boots the agent out before replacing the app and bootstraps it after.

## Status (2026-09-23)

v1 (phases 1–5) is done, running at login, and pushed to github.com/dfmedina/herdrbar (public).
Repo-local git author is dfmedina (`5438664+dfmedina@users.noreply.github.com`); remote uses the SSH
host alias `github-dfmedina` (`~/.ssh/config` → `~/.ssh/id_ed25519`). `gh` is logged in as diefmedina.
Workflow: edit `Sources/main.swift` → `./build.sh` (restarts the running app) → user tests on the Touch Bar.
Don't quit herdr to test anything: the Claude session runs inside it.

## Next (v2) — build phase by phase, test each with the user

Suggested order: 6 + 8 together, then 7, then 9, then 10.

6. **Waiting agents in other workspaces** — today only the focused workspace is shown, so a 🔴 blocked
   agent elsewhere is invisible. Add one extra button, e.g. `🔴 2 elsewhere` (count blocked tabs outside
   the focused workspace; maybe ✅ done too — ask). Hidden when the count is 0. Tap → `herdr tab focus`
   the first such tab (herdr switches workspace) + bring Ghostty forward. `herdr tab list` already
   returns tabs of all workspaces, so no extra command is needed.
   **Done 2026-09-23.** Counts blocked + done tabs elsewhere (`🔴 1 ✅ 2 elsewhere`, zero counts omitted);
   red bezel if any is blocked. Tap jumps to the first blocked tab, else the first done one (then workspace
   order, then tab number). `Herdr.snapshot()` returns focused-workspace tabs + this list; still 2 calls/s.
7. **Instant updates via events** — replace the 1 s poll (2 `herdr` processes/s) with a long-running
   subscription: herdr `events.subscribe`, event `pane.agent_status_changed` (check `herdr --help` / docs
   for the exact CLI or socket protocol at `~/.config/herdr/herdr.sock`). On any event, re-fetch tabs.
   Keep a slow fallback poll (e.g. 10 s) for tab add/remove/rename/focus if those have no events, and
   to recover if herdr restarts.

   **Plan (researched 2026-09-23, herdr 0.9.1, API protocol 22):**
   - Protocol: Unix socket `~/.config/herdr/herdr.sock`, newline-delimited JSON. Request
     `{"id":"1","method":"...","params":{...}}` → `{"id":"1","result":{...}}` (or `"error"`). Full schema:
     `herdr api schema --json`.
   - Subscribing: `events.subscribe` with `params.subscriptions: [{"type": "<kind>"}, ...]` → replies
     `{"result":{"type":"subscription_started"}}`, then streams `{"event": ..., "data": ...}` lines on the
     same connection. Structural kinds need no args: `workspace.focused/created/closed/renamed`,
     `tab.created/closed/focused/renamed/moved`, `pane.created/closed/updated/exited/agent_detected`.
   - Catch: `pane.agent_status_changed` **requires a `pane_id`** (one subscription per pane). Open
     question: does `pane.updated` (no args; carries `agent_status`) also fire on status changes? A probe
     logging all events is running — check its log before coding. If yes → subscribe to `pane.updated` only.
     If no → add one `pane.agent_status_changed` per pane id from the snapshot, and reconnect with a new
     list whenever the set of pane ids changes.
   - Data: replace the 2 CLI calls with one socket request, `session.snapshot` (same as
     `herdr api snapshot`): `workspaces`, `tabs` (same fields as `tab list`), `panes`,
     `focused_workspace_id`. Tap → socket `tab.focus` too. Result: **no `herdr` processes at all.**
   - Code shape: `HerdrSocket` (POSIX `socket(AF_UNIX)` + `connect`; `request(method, params)` = connect,
     write one line, read one line, close). `EventStream` on a background thread: connect, subscribe, read
     lines; any event → refresh on main, debounced ~100 ms. On EOF/error → treat as maybe-off, refresh,
     retry the connection every 3 s.
   - Keep a 10 s fallback timer (belt and braces; covers missed events and focus changes made in herdr
     if those don't all emit events).
   - Test: switch tabs/workspaces in herdr, create/close/rename a tab, let an agent go working→done/
     blocked — bar should update with no visible lag; `ps` shows no `herdr` child processes; CPU ~0.
   - Risk: the socket API is versioned (`protocol: 22`); a herdr update could change it. On decode
     failures, log once and fall back to the 1 s CLI poll? — keep it simple unless it happens.
   **Built 2026-09-24, not yet verified.** Socket client + `EventStream` as planned (subscribes to both
   `pane.updated` and per-pane `pane.agent_status_changed`, logs them). Tab focus events confirmed working
   (probe). Open issue: after launch, a working→done change on the CC pane logged **no** status event, so
   status may only update via the 10 s fallback — investigate before marking done.
8. **Make "blocked" stand out** — red `bezelColor` on blocked tabs (e.g. `.systemRed`); the accent color
   stays for the focused tab. Decide with the user what a focused *and* blocked tab looks like.
   **Done 2026-09-23.** Blocked tabs get `.systemRed`; red wins on a focused + blocked tab.
9. **Many tabs** — ~7+ tabs overflow the bar even with the 16-char cap. Switch the tab buttons to a
   horizontally scrolling row (`NSScrubber`, or an `NSScrollView` of buttons inside one custom item) when
   they don't fit. Keep per-tab lookup by `tab_id` (see phase 2 note on item reuse).
10. **Long-press actions** — e.g. long-press a tab button → menu/popover: jump to the first blocked agent,
   new tab (`herdr tab --help` for the create command). Use `NSPressGestureRecognizer` on the button.

## Housekeeping

- **Test "herdr off"** at a moment herdr isn't running (outside a herdr-hosted session): bar shows
  "herdr off", tap opens Ghostty, tab buttons return by themselves once herdr is back.
- **Test start at login** on the next real login/restart (buttons should appear on their own).
- Ghostty is hard-coded (`com.mitchellh.ghostty`) — fine unless the user changes terminal.

## Risks

- Private APIs could break in a future macOS update → the app simply stops showing buttons.
- Function-keys mode might hide system-modal bars → check in phase 1; if so, the user changes
  that one Touch Bar setting.
- Touch Bar flickers in dim light (OLED hardware wear; not software). A lamp helps; unrelated to this app.

## Removal

`./login.sh off`, then delete `~/Applications/HerdrBar.app`, `~/Library/Logs/HerdrBar.log` and this folder.
