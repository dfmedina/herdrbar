// HerdrBar — Touch Bar control panel for herdr.
// One Touch Bar button per herdr tab (focused workspace) with live agent status; tap to jump to the tab.
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

private struct Response<T: Decodable>: Decodable { let result: T? }
private struct WorkspaceList: Decodable { let workspaces: [Workspace] }
private struct TabList: Decodable { let tabs: [Tab] }

enum Herdr {
    static let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path

    /// Runs `herdr <args>` and decodes `result`; nil if herdr is missing, not running, or slow.
    static func run<T: Decodable>(_ args: [String], as _: T.Type) -> T? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONDecoder().decode(Response<T>.self, from: data))?.result
    }

    /// Tabs of the focused workspace sorted by number, or nil if herdr is not reachable.
    static func tabs() -> [Tab]? {
        guard let workspaces = run(["workspace", "list"], as: WorkspaceList.self)?.workspaces,
              let tabs = run(["tab", "list"], as: TabList.self)?.tabs else { return nil }
        let focused = workspaces.first(where: \.focused)?.workspace_id
        return tabs.filter { focused == nil || $0.workspace_id == focused }.sorted { $0.number < $1.number }
    }

    private struct TabInfo: Decodable { let tab: Tab }

    /// Focuses the tab in herdr; false if herdr refused or isn't running.
    static func focus(_ tabID: String) -> Bool {
        run(["tab", "focus", tabID], as: TabInfo.self) != nil
    }

    static let icons = ["working": "⏳", "blocked": "🔴", "done": "✅", "idle": "⚪"]

    static let maxNameLength = 16

    static func title(for tab: Tab) -> String {
        var name = (tab.label?.isEmpty == false ? tab.label! : "Tab \(tab.number)")
        if name.count > maxNameLength { name = name.prefix(maxNameLength - 1) + "…" }
        guard let icon = tab.agent_status.flatMap({ icons[$0] }) else { return name }
        return "\(icon) \(name)"
    }
}

// MARK: - App

let trayID = NSTouchBarItem.Identifier("dev.local.herdrbar.tray")
let offID = NSTouchBarItem.Identifier("dev.local.herdrbar.off")

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    private let bar = NSTouchBar()
    private var trayItem: NSCustomTouchBarItem!
    private var tabs: [Tab] = []
    private var fetching = false

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
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard !fetching else { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            let tabs = Herdr.tabs()
            DispatchQueue.main.async {
                self.fetching = false
                self.show(tabs ?? [])
            }
        }
    }

    private func itemID(_ tab: Tab) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("dev.local.herdrbar.tab.\(tab.tab_id)")
    }

    private func show(_ newTabs: [Tab]) {
        guard newTabs != tabs else { return }
        let sameLayout = newTabs.map(\.tab_id) == tabs.map(\.tab_id)
        tabs = newTabs
        if !sameLayout {
            bar.defaultItemIdentifiers = tabs.isEmpty ? [offID] : tabs.map(itemID)
        }
        // NSTouchBar reuses existing items across layout changes, so look buttons up rather than caching them.
        for tab in tabs {
            guard let button = (bar.item(forIdentifier: itemID(tab)) as? NSCustomTouchBarItem)?.view as? NSButton
            else { continue }
            style(button, for: tab)
        }
    }

    private func style(_ button: NSButton, for tab: Tab) {
        button.title = Herdr.title(for: tab)
        button.bezelColor = tab.focused ? .controlAccentColor : nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        if id == offID {
            item.view = NSButton(title: "herdr off", target: self, action: #selector(bringGhosttyForward))
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
