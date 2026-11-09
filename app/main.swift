import Cocoa
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
let appDir = home + "/.office-room"
let port = ProcessInfo.processInfo.environment["OFFICE_PORT"] ?? "4777"
let base = URL(string: "http://127.0.0.1:\(port)/")!

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: OfficeStore!
    var server: Process?
    var serverStdin: Pipe?
    var quitting = false
    var connected = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        store = OfficeStore(base: base)
        let scene = OfficeScene(frame: .zero)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Office Room"; window.minSize = NSSize(width: 800, height: 560)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: OfficeRoot(store: store, scene: scene))
        window.setFrameAutosaveName("OfficeRoomMain")
        if !window.setFrameUsingName("OfficeRoomMain") { window.center() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async { self.startServer() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard connected, let store = store else { return }
        store.perform("api/agents/discover") { store.agents = $0 }
    }
    func startServer() {
        if ping() { DispatchQueue.main.async { self.connected = true; self.store.connect() }; return }
        // Dev checkout in ~/.office-room wins; otherwise use the copy bundled in the app (friends' machines).
        let res = Bundle.main.resourcePath ?? ""
        let fm = FileManager.default
        let serverJS = fm.fileExists(atPath: appDir + "/server.js") ? appDir + "/server.js" : res + "/server/server.js"
        let bundledNode = res + "/node/bin/node"
        let node = fm.isExecutableFile(atPath: bundledNode) ? bundledNode : "node"
        try? fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; exec \"$OFFICE_NODE\" \"$OFFICE_SERVER\""]
        var env = ProcessInfo.processInfo.environment; env["OFFICE_PARENT_PIPE"] = "1"; env["OFFICE_PORT"] = port
        env["OFFICE_NODE"] = node; env["OFFICE_SERVER"] = serverJS; env["OFFICE_DATA"] = appDir + "/data"; p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: appDir)
        let stdin = Pipe(); p.standardInput = stdin
        let logURL = URL(fileURLWithPath: appDir + "/data/server.log")
        try? FileManager.default.createDirectory(atPath: appDir + "/data", withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { _ = FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let log = try? FileHandle(forWritingTo: logURL) { log.seekToEndOfFile(); p.standardOutput = log; p.standardError = log }
        p.terminationHandler = { [weak self] _ in guard let self = self, !self.quitting else { return }; DispatchQueue.main.async { self.store.notice = "ตัวจัดการงานหยุดทำงาน · ลองเปิดแอปใหม่" } }
        do { try p.run() } catch { DispatchQueue.main.async { self.store.notice = "เปิดตัวจัดการงานไม่ได้: \(error.localizedDescription)" }; return }
        server = p; serverStdin = stdin
        for _ in 0..<60 {
            if ping() { DispatchQueue.main.async { self.connected = true; self.store.connect() }; return }
            if !p.isRunning { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        DispatchQueue.main.async { self.store.notice = "ตัวจัดการงานไม่ตอบ · ตรวจสอบ data/server.log" }
    }
    func ping() -> Bool { get("api/ping", timeout: 0.5) != nil }
    func get(_ path: String, timeout: TimeInterval) -> Data? {
        var req = URLRequest(url: base.appendingPathComponent(path)); req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0); var out: Data?
        URLSession.shared.dataTask(with: req) { d, r, _ in if (r as? HTTPURLResponse)?.statusCode == 200 { out = d }; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5); return out
    }
    func runningRooms() -> Int {
        guard let d = get("api/state", timeout: 1), let j = try? JSONSerialization.jsonObject(with: d) as? JSONObject, let rooms = j["rooms"] as? [JSONObject] else { return 0 }
        return rooms.filter { ($0["status"] as? String) == "running" }.count
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        let n = runningRooms()
        if n > 0, server?.isRunning == true {
            let a = NSAlert(); a.messageText = "Agent กำลังทำงานอยู่ \(n) ห้อง"; a.informativeText = "ถ้าปิดแอปตอนนี้ งานรอบนี้จะหยุด เปิดแอปใหม่แล้วกด ลองใหม่ เพื่อทำต่อได้"; a.addButton(withTitle: "ปิดแอป"); a.addButton(withTitle: "ยกเลิก")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        quitting = true; store.stop()
        if let p = server, p.isRunning {
            p.terminate(); let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        return .terminateNow
    }
    @objc func reload() { store.refresh() }
    func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) { let it = NSMenuItem(); let m = NSMenu(title: title); items.forEach { m.addItem($0) }; it.submenu = m; main.addItem(it) }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem { let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; return i }
        add("Office Room", [item("เกี่ยวกับ Office Room", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), .separator(), item("ซ่อน Office Room", #selector(NSApplication.hide(_:)), "h"), item("ซ่อนแอปอื่น", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]), .separator(), item("ปิด Office Room", #selector(NSApplication.terminate(_:)), "q")])
        let editing = NativeEditActions.shared
        let editItems = [item("Undo", #selector(NativeEditActions.undo(_:)), "z"), item("Redo", #selector(NativeEditActions.redo(_:)), "z", [.command, .shift]), .separator(), item("ตัด", #selector(NativeEditActions.cut(_:)), "x"), item("คัดลอก", #selector(NativeEditActions.copy(_:)), "c"), item("วาง", #selector(NativeEditActions.paste(_:)), "v"), item("เลือกทั้งหมด", #selector(NativeEditActions.selectAll(_:)), "a")]
        for entry in editItems where !entry.isSeparatorItem { entry.target = editing }
        add("แก้ไข", editItems)
        let refresh = item("อัปเดตข้อมูล", #selector(reload), "r"); refresh.target = self
        add("มุมมอง", [refresh, item("เต็มจอ", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        add("หน้าต่าง", [item("ย่อ", #selector(NSWindow.performMiniaturize(_:)), "m"), item("ขยาย", #selector(NSWindow.performZoom(_:)), "")])
        NSApp.mainMenu = main
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
