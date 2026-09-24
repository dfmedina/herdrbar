// HerdrBar — Touch Bar control panel for herdr.
// One Touch Bar button per herdr tab (focused workspace) with live agent status; tap to jump to the tab.
// Talks to herdr's socket directly: an event subscription drives updates, with a slow fallback poll.
// An extra button counts blocked/done agents in other workspaces and jumps to the first one.
import AppKit

// MARK: - Logging (~/Library/Logs/HerdrBar.log; NSLog lines don't reliably reach `log show`)

private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HerdrBar.log")

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Private Touch Bar APIs

private let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

private func dfrSymbol<T>(_ name: String, as _: T.Type) -> T? {
    guard let dfr, let sym = dlsym(dfr, name) else { log("missing \(name)"); return nil }
    return unsafeBitCast(sym, to: T.self)
}

private typealias SetPresenceFn = @convention(c) (CFString, Bool) -> Void
private typealias ShowsCloseBoxFn = @convention(c) (Bool) -> Void

private let setControlStripPresence = dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetPresenceFn.self)
private let showsCloseBox = dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: ShowsCloseBoxFn.self)

private func callClass(_ cls: AnyClass, _ selector: String, _ a: Any?, _ b: Any? = nil) {
    let sel = NSSelectorFromString(selector)
    guard let obj = cls as AnyObject as? NSObject, obj.responds(to: sel) else {
        log("\(cls) does not respond to \(selector)")
        return
    }
    if let b { _ = obj.perform(sel, with: a, with: b) } else { _ = obj.perform(sel, with: a) }
}

private typealias PresentPlacementFn = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString) -> Void

/// `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` — placement 0 leaves the Control Strip
/// visible; 1 covers the whole bar. Falls back to the two-argument variant if missing.
private func presentSystemModal(_ bar: NSTouchBar, placement: Int64, id: String) {
    let sel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    guard let method = class_getClassMethod(NSTouchBar.self, sel) else {
        callClass(NSTouchBar.self, "presentSystemModalTouchBar:systemTrayItemIdentifier:", bar, id)
        return
    }
    let fn = unsafeBitCast(method_getImplementation(method), to: PresentPlacementFn.self)
    fn(NSTouchBar.self, sel, bar, placement, id as NSString)
}

// MARK: - App

// MARK: - herdr

struct Tab: Decodable, Equatable {
    let tab_id: String
    let workspace_id: String
    let number: Int
    let label: String?
    let focused: Bool
    let agent_status: String?
}

private struct Workspace: Decodable {
    let workspace_id: String
    let focused: Bool
}

private struct Pane: Decodable { let pane_id: String }

private struct Response<T: Decodable>: Decodable { let result: T? }
private struct SessionSnapshot: Decodable { let snapshot: Session }
private struct Session: Decodable {
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
}

/// herdr's socket API: newline-delimited JSON over `~/.config/herdr/herdr.sock` (`herdr api schema --json`).
enum HerdrSocket {
    static let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr/herdr.sock").path

    /// A connected socket, or nil if herdr isn't running.
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func send(_ fd: Int32, method: String, params: [String: Any] = [:]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: ["id": "1", "method": method, "params": params])
        else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
    }

    /// One request on a fresh connection; decodes `result`, nil on error, timeout (3 s) or herdr not running.
    static func request<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as _: T.Type) -> T? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard send(fd, method: method, params: params), let line = LineReader(fd: fd).next() else { return nil }
        return (try? JSONDecoder().decode(Response<T>.self, from: line))?.result
    }
}

/// Splits a socket's byte stream into lines.
final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    /// The next line without its newline; nil on EOF, error or timeout.
    func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// Keeps an `events.subscribe` connection open on a background thread and calls `onEvent` with each event
/// name ("disconnected" when the connection drops). Reconnects every 3 s while herdr is down.
final class EventStream {
    /// Events that need no arguments. Status changes are subscribed per pane: `pane.agent_status_changed`
    /// requires a pane_id, and `pane.updated` does not fire on status changes (verified with herdr 0.9.1).
    private static let kinds = [
        "workspace.created", "workspace.closed", "workspace.renamed", "workspace.focused", "workspace.reordered",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.closed", "pane.exited", "pane.agent_detected",
    ]

    private let onEvent: (String) -> Void
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var paneIDs: [String] = []

    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    func start() { Thread { self.loop() }.start() }

    /// Resubscribes when the set of panes changes, so every pane's status changes are delivered.
    func watch(panes: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard panes != paneIDs else { return }
        paneIDs = panes
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private func loop() {
        while true {
            guard let fd = HerdrSocket.connect() else { Thread.sleep(forTimeInterval: 3); continue }
            lock.lock(); self.fd = fd; let panes = paneIDs; lock.unlock()
            let subscriptions: [[String: String]] = Self.kinds.map { ["type": $0] }
                + panes.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
            if HerdrSocket.send(fd, method: "events.subscribe", params: ["subscriptions": subscriptions]) {
                let reader = LineReader(fd: fd)
                while let line = reader.next() {
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if let error = message["error"] { log("subscribe error: \(error)") }
                    guard let event = message["event"] as? String else { continue }
                    onEvent(event)
                }
            }
            lock.lock(); close(fd); self.fd = -1; lock.unlock()
            onEvent("disconnected")
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}

enum Herdr {
    struct Snapshot: Equatable {
        /// Tabs of the focused workspace, sorted by number.
        var tabs: [Tab] = []
        /// Blocked or done tabs in other workspaces: blocked first, then workspace order, then number.
        var elsewhere: [Tab] = []
        var paneIDs: [String] = []
    }

    /// Current herdr state (one `session.snapshot` request), or nil if herdr is not reachable.
    static func snapshot() -> Snapshot? {
        guard let session = HerdrSocket.request("session.snapshot", as: SessionSnapshot.self)?.snapshot else { return nil }
        let workspaces = session.workspaces, tabs = session.tabs
        let focused = workspaces.first(where: \.focused)?.workspace_id
        let order = Dictionary(workspaces.enumerated().map { ($1.workspace_id, $0) }, uniquingKeysWith: { a, _ in a })
        let attention = ["blocked": 0, "done": 1]
        let rank = { (tab: Tab) in (attention[tab.agent_status ?? ""] ?? 2, order[tab.workspace_id] ?? .max, tab.number) }
        return Snapshot(
            tabs: tabs.filter { focused == nil || $0.workspace_id == focused }.sorted { $0.number < $1.number },
            elsewhere: tabs.filter { focused != nil && $0.workspace_id != focused && attention[$0.agent_status ?? ""] != nil }
                .sorted { rank($0) < rank($1) },
            paneIDs: session.panes.map(\.pane_id).sorted()
        )
    }

    private struct TabInfo: Decodable { let tab: Tab }

    /// Focuses the tab in herdr; false if herdr refused or isn't running.
    static func focus(_ tabID: String) -> Bool {
        HerdrSocket.request("tab.focus", ["tab_id": tabID], as: TabInfo.self) != nil
    }

    static let icons = ["working": "⏳", "blocked": "🔴", "done": "✅", "idle": "⚪"]

    static let maxNameLength = 16

    static func title(for tab: Tab) -> String {
        var name = (tab.label?.isEmpty == false ? tab.label! : "Tab \(tab.number)")
        if name.count > maxNameLength { name = name.prefix(maxNameLength - 1) + "…" }
        guard let icon = tab.agent_status.flatMap({ icons[$0] }) else { return name }
        return "\(icon) \(name)"
    }

    /// e.g. "🔴 1 ✅ 2 elsewhere"; zero counts are left out.
    static func elsewhereTitle(for tabs: [Tab]) -> String {
        let parts = ["blocked", "done"].compactMap { status -> String? in
            let count = tabs.filter { $0.agent_status == status }.count
            return count > 0 ? "\(icons[status]!) \(count)" : nil
        }
        return (parts + ["elsewhere"]).joined(separator: " ")
    }
}

// MARK: - App

let trayID = NSTouchBarItem.Identifier("dev.local.herdrbar.tray")
let offID = NSTouchBarItem.Identifier("dev.local.herdrbar.off")
let elsewhereID = NSTouchBarItem.Identifier("dev.local.herdrbar.elsewhere")

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    private let bar = NSTouchBar()
    private var trayItem: NSCustomTouchBarItem!
    private var state = Herdr.Snapshot()
    private var tabs: [Tab] { state.tabs }
    private var fetching = false
    private var refetch = false
    private var refreshScheduled = false
    private lazy var events = EventStream { [weak self] _ in
        DispatchQueue.main.async { self?.scheduleRefresh() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("launched")
        // A windowless accessory app is a candidate for automatic termination; keep it alive.
        ProcessInfo.processInfo.disableAutomaticTermination("Touch Bar controller")
        ProcessInfo.processInfo.disableSuddenTermination()
        bar.delegate = self
        bar.defaultItemIdentifiers = [offID]

        trayItem = NSCustomTouchBarItem(identifier: trayID)
        // The 🐑 is only visible while the bar is hidden (via the system ✕), so tapping it always presents.
        trayItem.view = NSButton(title: "🐑", target: self, action: #selector(present))
        callClass(NSTouchBarItem.self, "addSystemTrayItem:", trayItem)
        setControlStripPresence?(trayID.rawValue as CFString, true)
        showsCloseBox?(true)

        present()
        refresh()
        events.start()
        // Events drive updates; the slow poll only covers anything they miss.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Coalesces bursts of events (a tab switch sends several) into one refresh.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        // An event during a fetch may postdate its snapshot: fetch again once it finishes.
        guard !fetching else { refetch = true; return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            let snapshot = Herdr.snapshot()
            DispatchQueue.main.async {
                self.fetching = false
                self.show(snapshot ?? Herdr.Snapshot())
                if let snapshot { self.events.watch(panes: snapshot.paneIDs) }
                if self.refetch { self.refetch = false; self.refresh() }
            }
        }
    }

    private func itemID(_ tab: Tab) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("dev.local.herdrbar.tab.\(tab.tab_id)")
    }

    private func layout(_ state: Herdr.Snapshot) -> [NSTouchBarItem.Identifier] {
        if state.tabs.isEmpty { return [offID] }
        return state.tabs.map(itemID) + (state.elsewhere.isEmpty ? [] : [elsewhereID])
    }

    private func show(_ newState: Herdr.Snapshot) {
        guard newState != state else { return }
        let sameLayout = layout(newState) == layout(state)
        state = newState
        if !sameLayout {
            bar.defaultItemIdentifiers = layout(state)
        }
        // NSTouchBar reuses existing items across layout changes, so look buttons up rather than caching them.
        for tab in tabs {
            guard let button = button(for: itemID(tab)) else { continue }
            style(button, for: tab)
        }
        if let button = button(for: elsewhereID) { styleElsewhere(button) }
    }

    private func button(for id: NSTouchBarItem.Identifier) -> NSButton? {
        (bar.item(forIdentifier: id) as? NSCustomTouchBarItem)?.view as? NSButton
    }

    private func style(_ button: NSButton, for tab: Tab) {
        button.title = Herdr.title(for: tab)
        // Blocked wins over focused: the focused tab is the one on screen anyway.
        button.bezelColor = tab.agent_status == "blocked" ? .systemRed : tab.focused ? .controlAccentColor : nil
    }

    private func styleElsewhere(_ button: NSButton) {
        button.title = Herdr.elsewhereTitle(for: state.elsewhere)
        button.bezelColor = state.elsewhere.contains { $0.agent_status == "blocked" } ? .systemRed : nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        if id == offID {
            item.view = NSButton(title: "herdr off", target: self, action: #selector(bringGhosttyForward))
        } else if id == elsewhereID {
            let button = NSButton(title: "", target: self, action: #selector(tappedElsewhere))
            styleElsewhere(button)
            item.view = button
        } else if let tab = tabs.first(where: { itemID($0) == id }) {
            let button = NSButton(title: "", target: self, action: #selector(tapped(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tab.tab_id)
            style(button, for: tab)
            item.view = button
        } else {
            return nil
        }
        return item
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let tabID = sender.identifier?.rawValue else { return }
        focus(tabID)
    }

    /// Jumps to the first blocked (else done) tab in another workspace; herdr switches workspace itself.
    @objc private func tappedElsewhere() {
        guard let tab = state.elsewhere.first else { return }
        focus(tab.tab_id)
    }

    private func focus(_ tabID: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Herdr.focus(tabID)
            if !ok { log("focus \(tabID) failed") }
            DispatchQueue.main.async {
                self.bringGhosttyForward()
                self.refresh()
            }
        }
    }

    @objc private func bringGhosttyForward() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
            log("Ghostty not found")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func present() {
        presentSystemModal(bar, placement: 0, id: trayID.rawValue)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
