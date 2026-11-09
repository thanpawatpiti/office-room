import SwiftUI
import SceneKit

typealias NativeState<T> = SwiftUI.State<T>

enum OfficeStyle {
    static func color(_ hex: UInt32) -> Color { Color(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
    static let warning = color(0x845417), failure = color(0xA5332A)
    static let canvas = color(0xF4F6F7), surface = Color.white, ink = color(0x202A33), muted = color(0x596773), accent = color(0x176C65), border = color(0xDCE2E6)
    static func agentColor(_ id: String) -> Color { color(agentAccent(id)) }
    static func roomStatus(_ status: String?) -> String { ["running":"กำลังทำงาน", "waiting":"รอคุณ", "done":"เสร็จแล้ว", "idle":"พร้อม"][status ?? ""] ?? "พร้อมเริ่มงาน" }
}
extension View {
    func officeCard() -> some View { padding(14).background(OfficeStyle.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(OfficeStyle.border)) }
}

struct OfficeSceneView: NSViewRepresentable {
    let scene: OfficeScene
    let state: JSONObject
    func makeNSView(context: Context) -> OfficeScene { scene }
    func updateNSView(_ view: OfficeScene, context: Context) { view.update(state) }
}

struct OfficeRoot: View {
    @ObservedObject var store: OfficeStore
    let scene: OfficeScene
    @NativeState(wrappedValue: false) private var showSettings: Bool
    @NativeState(wrappedValue: false) private var showNew: Bool
    @NativeState(wrappedValue: false) private var showRooms: Bool
    @NativeState(wrappedValue: true) private var showChat: Bool
    @NativeState(wrappedValue: false) private var chatManuallyChosen: Bool
    @NativeState(wrappedValue: "") private var message: String
    @NativeState(wrappedValue: []) private var messageImages: [DraftImage]
    @NativeState(wrappedValue: false) private var sending: Bool
    @NativeState(wrappedValue: false) private var confirmDelete: Bool
    @NativeState(wrappedValue: false) private var showingDiff: Bool
    @NativeState(wrappedValue: "") private var diff: String
    @NativeState(wrappedValue: false) private var showingSessions: Bool
    @NativeState(wrappedValue: false) private var activityPaused: Bool
    @NativeState(wrappedValue: nil) private var question: JSONObject?
    @NativeState(wrappedValue: nil) private var document: JSONObject?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    workspace
                    if showChat {
                        Divider()
                        chatPanel.frame(width: min(380, max(300, geometry.size.width * 0.28)))
                    }
                }
            }.background(OfficeStyle.canvas).foregroundStyle(OfficeStyle.ink).tint(OfficeStyle.accent)
             .onAppear { if !chatManuallyChosen { showChat = geometry.size.width >= 1000 } }
             .onChange(of: geometry.size.width) { width in if !chatManuallyChosen { showChat = width >= 1000 } }
        }
        .preferredColorScheme(.light)
        .frame(minWidth: 800, minHeight: 560)
        .sheet(isPresented: $showNew) { NewRoomView(store: store, initialTask: store.room == nil ? message : "", initialImages: store.room == nil ? messageImages : [], onCreated: { message = ""; messageImages = [] }) }
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showRooms) { RoomListView(store: store) }
        .sheet(isPresented: $showingDiff) { TextSheet(title: "สิ่งที่ทีมแก้ไป (Diff)", text: diff) }
        .sheet(isPresented: $showingSessions) { TextSheet(title: "เปิดคุยต่อใน CLI", text: sessionText) }
        .sheet(isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } })) { if let q = question { if q["kind"] as? String == "questions" { StructuredQuestionView(store: store, question: q).id(q["key"] as? String ?? "") } else { QuestionView(store: store, question: q) } } }
        .sheet(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } })) { if let d = document { DocumentView(document: d) } }
        .onChange(of: store.pendingQuestion()?["key"] as? String) { _ in popQuestion() }
        .onChange(of: otherSheetOpen) { _ in popQuestion() }
        .onAppear(perform: popQuestion)
        .alert("ลบห้องนี้?", isPresented: $confirmDelete) {
            Button("ยกเลิก", role: .cancel) {}
            Button("ลบห้อง", role: .destructive) { if let id = store.selectedID { store.perform("api/rooms/\(id)", method: "DELETE") { _ in store.select(nil) } } }
        } message: { Text("ประวัติห้องจะถูกลบ แต่ไฟล์ในโปรเจกต์จะไม่ถูกลบ") }
        .alert("เกิดข้อผิดพลาด", isPresented: Binding(get: { store.error != nil && !otherSheetOpen && question == nil }, set: { if !$0 { store.error = nil } })) { Button("ตกลง") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    var toolbar: some View {
        HStack(spacing: 12) {
            Label("Office Room", systemImage: "square.stack.3d.up").font(.system(size: 16, weight: .semibold))
            if let title = store.room?["title"] as? String { Text(title).font(.callout).foregroundStyle(OfficeStyle.muted).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 8)
            Button { showRooms = true } label: { Label("ห้องงาน", systemImage: "square.grid.2x2") }.help("เปิดห้องงาน")
            Button { showNew = true } label: { Label("งานใหม่", systemImage: "plus") }.buttonStyle(.borderedProminent)
            Button { chatManuallyChosen = true; showChat.toggle() } label: { Image(systemName: "sidebar.right") }.help(showChat ? "พับแชต" : "เปิดแชต").accessibilityLabel(showChat ? "พับแชต" : "เปิดแชต").keyboardShortcut("c", modifiers: [.command, .shift])
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("ตั้งค่า").accessibilityLabel("ตั้งค่า")
        }.controlSize(.large).padding(.horizontal, 20).padding(.vertical, 12).background(OfficeStyle.surface)
    }
    var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ทีมในเครื่อง").font(.caption.weight(.semibold)).foregroundStyle(OfficeStyle.muted)
                    Text("พบ \(store.agentIDs.count) CLI").font(.caption).foregroundStyle(OfficeStyle.accent)
                    Spacer()
                    if !store.notice.isEmpty { Text(store.notice).font(.caption).foregroundStyle(OfficeStyle.muted).lineLimit(1).help(store.notice) }
                }
                if store.agents.isEmpty { Text("กำลังเชื่อมต่อและตรวจหา CLI…").font(.callout).foregroundStyle(OfficeStyle.muted).padding(.vertical, 8) }
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(store.agents.keys.sorted(), id: \.self) { agent in
                            UsageCard(agent: agent, info: store.agents[agent] as? JSONObject ?? [:], refresh: { store.perform("api/agents/\(agent)/refresh") }).frame(width: 280)
                        }
                    }.padding(.bottom, 3)
                }
            }.padding(.horizontal, 20).padding(.top, 14)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.room?["title"] as? String ?? "ออฟฟิศของคุณ").font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    if let room = store.room {
                        let running = room["running"] as? JSONObject ?? [:]
                        let assignments = room["assignments"] as? JSONObject ?? [:]
                        let current = assignments[running["agent"] as? String ?? ""] as? JSONObject ?? [:]
                        let brief = room["briefing"] as? JSONObject ?? [:]
                        Text(current["assignment"] as? String ?? brief["firstStep"] as? String ?? brief["summary"] as? String ?? "กำลังบรีฟโจทย์และจัดทีม…").font(.callout).foregroundStyle(OfficeStyle.muted).lineLimit(2)
                    } else { Text("เลือกงาน แล้วให้ทีมแบ่งหน้าที่ตามสิ่งที่ต้องทำ").font(.callout).foregroundStyle(OfficeStyle.muted) }
                }
                Spacer(minLength: 8)
                Text(OfficeStore.phases.first(where: { $0.id == (store.room?["workflow"] as? JSONObject)?["phase"] as? String })?.label ?? OfficeStyle.roomStatus(store.room?["status"] as? String)).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6).background(OfficeStyle.accent.opacity(0.08), in: Capsule()).foregroundStyle(OfficeStyle.accent)
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            ZStack(alignment: .bottomLeading) {
                OfficeSceneView(scene: scene, state: store.sceneState())
                HStack(spacing: 6) {
                    Button { scene.rotateLeft() } label: { Image(systemName: "rotate.left") }.help("หมุนซ้าย").accessibilityLabel("หมุนซ้าย")
                    Button { scene.rotateRight() } label: { Image(systemName: "rotate.right") }.help("หมุนขวา").accessibilityLabel("หมุนขวา")
                    Button { scene.resetView() } label: { Image(systemName: "viewfinder") }.help("รีเซ็ตมุมมอง").accessibilityLabel("รีเซ็ตมุมมอง")
                    Text("ลากเพื่อหมุน · เลื่อนเพื่อซูม").font(.caption).foregroundStyle(OfficeStyle.muted)
                }.padding(10).background(OfficeStyle.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 10)).padding(16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            roomFooter
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var roomFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let room = store.room {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        let running = room["running"] as? JSONObject ?? [:]
                        let assignments = room["assignments"] as? JSONObject ?? [:]
                        let agent = running["agent"] as? String ?? room["lead"] as? String ?? ""
                        let selected = assignments[agent] as? JSONObject ?? [:]
                        let effort = running["effort"] as? String ?? selected["effort"] as? String ?? "ค่าเริ่มต้น CLI"
                        let model = running["model"] as? String ?? selected["model"] as? String ?? ""
                        Text(agent.isEmpty ? "ทีมพร้อมรับงาน" : [store.agentName(agent), model, effort].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(running["role"] as? String == "coordinator" ? "กำลังบรีฟโจทย์และเลือกผู้รับผิดชอบตามงาน" : selected["reason"] as? String ?? room["leadReason"] as? String ?? "อ่านบทสนทนาเพื่อดูความคืบหน้า").font(.caption).foregroundStyle(OfficeStyle.muted).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if store.isRunning { Button("หยุดงาน") { command("stop") } }
                    Menu {
                        Button("ดู Diff") { loadDiff() }; Button("เปิด Session") { showingSessions = true }
                        Button(activityPaused ? "เปลี่ยนข้อความเหนือหัวต่อ" : "พักข้อความเหนือหัว") { activityPaused.toggle(); scene.setActivityRotationPaused(activityPaused) }
                        Divider(); Button("ลบห้อง", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis") }.help("ตัวเลือกห้อง").accessibilityLabel("ตัวเลือกห้อง")
                }
                if room["status"] as? String == "waiting" { waitingButtons(room) }
                else if let q = store.pendingQuestion() { HStack { Text("มีคำถามรอคุณตอบ · งานอื่นทำต่อได้").font(.caption); Button("ตอบคำถาม") { question = q } } }
                if room["status"] as? String == "done" { Button("เริ่มงานใหม่") { message = ""; store.select(nil); showNew = true } }
            } else {
                HStack { Text("เริ่มจากโจทย์ที่คุณอยากให้ทีมช่วย").font(.callout).foregroundStyle(OfficeStyle.muted); Spacer(); Button("เริ่มงานใหม่") { showNew = true }.buttonStyle(.borderedProminent) }
            }
        }.padding(16).background(OfficeStyle.surface).overlay(alignment: .top) { Divider() }
    }
    var chatPanel: some View {
        VStack(spacing: 0) {
            HStack { Text("บทสนทนา").font(.headline); Spacer(); Button { chatManuallyChosen = true; showChat = false } label: { Image(systemName: "sidebar.right") }.help("พับแชต").accessibilityLabel("พับแชต") }.padding(16)
            Divider()
            if let room = store.room {
                WorkProgressView(room: room, openDocument: openDocument).padding(12)
                Divider()
                ConversationView(room: room)
            }
            else { VStack(spacing: 12) { Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(OfficeStyle.accent); Text("บอกสิ่งที่อยากให้ทีมช่วย").font(.headline); Text("พิมพ์โจทย์หรือแนบภาพด้านล่าง\nเพื่อเริ่มงานใหม่").multilineTextAlignment(.center).foregroundStyle(OfficeStyle.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                PromptInput(text: $message, images: $messageImages, title: store.room == nil ? "บอกสิ่งที่อยากให้ทีมช่วย…" : "คุยกับทีม…", height: 90, submit: send)
                HStack { if sending { ProgressView().controlSize(.small) }; Spacer(); Button(store.room == nil ? "สร้างงานจากข้อความนี้" : "ส่งข้อความ", action: send).buttonStyle(.borderedProminent).controlSize(.large).disabled(sending || (message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && messageImages.isEmpty)) }
            }.padding(14)
        }.background(OfficeStyle.surface)
    }
    @ViewBuilder func waitingButtons(_ room: JSONObject) -> some View {
        let kind = (room["waiting"] as? JSONObject)?["kind"] as? String ?? "ask"
        HStack {
            Text(["approve":"รออนุมัติแผน", "continue":"ให้ทีมทำงานต่อไหม", "retry":"งานหยุดชั่วคราว", "verify":"ยังตรวจงานไม่ครบ", "limit":"ติดขีดจำกัด", "ask":"รอคำตอบจากคุณ"][kind] ?? "รอคำตอบ").font(.caption)
            if let q = store.pendingQuestion() { Button(kind == "approve" ? "ดูแผน" : "ดูคำถาม") { question = q } }
            if kind == "approve" { Button("อนุมัติ") { decide("approve") } }
            if kind == "continue" { Button("ทำต่อ") { decide("continue") } }
            if kind == "retry" || kind == "limit" { Button("ลองใหม่") { decide("retry") } }
            if kind == "verify" { Button("ตรวจต่อ") { decide("retry") } }
            Button("ปิดงาน") { decide("cancel") }
        }
    }
    var otherSheetOpen: Bool { showNew || showSettings || showRooms || showingDiff || showingSessions || document != nil }
    func popQuestion() {
        guard let q = store.pendingQuestion(), let key = q["key"] as? String else { question = nil; return }
        // The open prompt was answered or expired elsewhere; never leave a stale one submittable.
        if question != nil && question?["key"] as? String != key { question = nil }
        guard question == nil, !otherSheetOpen, !store.shownQuestions.contains(key) else { return }
        store.shownQuestions.insert(key); question = q
        NSApp.requestUserAttention(.informationalRequest)
    }
    func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !text.isEmpty || !messageImages.isEmpty else { return }
        guard let id = store.selectedID, store.room != nil else { showNew = true; return }
        sending = true
        let images = messageImages
        store.uploadImages(images) { uploaded in
            switch uploaded {
            case .failure(let error): sending = false; store.error = error.localizedDescription
            case .success(let files):
                store.request("api/rooms/\(id)/message", method: "POST", body: ["text": text, "images": files.map { $0["id"] as? String ?? "" }]) { response in
                    sending = false
                    switch response {
                    case .failure(let error): store.error = error.localizedDescription
                    case .success:
                        if message.trimmingCharacters(in: .whitespacesAndNewlines) == text { message = "" }
                        let sent = Set(images.map(\.id)); messageImages.removeAll { sent.contains($0.id) }
                    }
                }
            }
        }
    }
    func command(_ action: String) { if let id = store.selectedID { store.perform("api/rooms/\(id)/\(action)") } }
    func decide(_ action: String) { if let id = store.selectedID { store.perform("api/rooms/\(id)/decide", body: ["action":action]) } }
    func openDocument(_ item: JSONObject) {
        guard let id = store.selectedID, let doc = item["id"] as? String else { return }
        store.perform("api/rooms/\(id)/documents/\(doc)", method: "GET") { document = $0 }
    }
    func loadDiff() { if let id = store.selectedID { store.perform("api/rooms/\(id)/diff", method: "GET") { diff = $0["diff"] as? String ?? ""; showingDiff = true } } }
    var sessionText: String {
        guard let r = store.room else { return "" }
        let dir = (r["dirs"] as? [String])?.first ?? "", sessions = r["sessions"] as? JSONObject ?? [:]
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return (["ควรเปิด session เมื่อตัวนั้นไม่ได้กำลังทำงาน"] + sessions.keys.sorted().map { id in
            let command = (store.agents[id] as? JSONObject)?["executablePath"] as? String ?? id
            let session = sessions[id] as? String ?? ""
            if id == "claude" { return store.agentName(id) + "\ncd \(quote(dir)) && \(quote(command)) --resume \(quote(session))" }
            if id == "codex" { return store.agentName(id) + "\ncd \(quote(dir)) && \(quote(command)) resume \(quote(session))" }
            return store.agentName(id) + "\nSession: " + session + "\nเปิดต่อผ่านตัวเชื่อมของ CLI นี้"
        }).joined(separator: "\n\n")
    }
}

extension Dictionary where Key == String, Value == Any {
    var roomID: String { self["id"] as? String ?? "" }
    var modelID: String { self["selector"] as? String ?? self["id"] as? String ?? "" }
}

struct ConversationView: View {
    let room: JSONObject
    // Follow new messages and streaming text only while the user is at the end of the chat.
    @NativeState(wrappedValue: true) private var atBottom: Bool
    var body: some View {
        GeometryReader { outer in ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(room["messages"] as? [JSONObject] ?? [], id: \.roomID) { item in MessageView(item: item) }
                    if let live = room["live"] as? JSONObject { MessageView(item: ["from": live["agent"] ?? "", "steps": live["steps"] ?? [], "live": true]) }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in Color.clear.preference(key: ChatBottom.self, value: g.frame(in: .named("chat")).maxY) })
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                 .background(ChatScrollObserver(atBottom: { atBottom = $0 }))
            }.coordinateSpace(name: "chat")
             // End marker's real position in the visible area; not laid out (scrolled far up) = infinity.
             .onChange(of: Self.progress(room)) { _ in if atBottom { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } } }
             .onChange(of: room.roomID) { _ in atBottom = true; DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
             .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        } }
    }
    // Changes whenever a message arrives or the live reply grows.
    static func progress(_ room: JSONObject) -> String {
        let steps = (room["live"] as? JSONObject)?["steps"] as? [JSONObject] ?? []
        let size = steps.reduce(0) { $0 + ($1["body"] as? String ?? "").count + ($1["output"] as? String ?? "").count }
        return "\((room["messages"] as? [JSONObject] ?? []).count):\(steps.count):\(size)"
    }
}
// Content growth changes the bottom gap without user scrolling. Track actual clip-view movement
// instead, so a streaming paragraph does not disable following its own next update.
struct ChatScrollObserver: NSViewRepresentable {
    var atBottom: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.changed = atBottom
        DispatchQueue.main.async { context.coordinator.attach(view.enclosingScrollView) }
    }
    final class Coordinator {
        weak var scroll: NSScrollView?
        var token: NSObjectProtocol?
        var lastY: CGFloat = 0
        var changed: ((Bool) -> Void)?
        func attach(_ value: NSScrollView?) {
            guard let value = value, value !== scroll else { return }
            if let token = token { NotificationCenter.default.removeObserver(token) }
            scroll = value; lastY = value.contentView.bounds.minY; value.contentView.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: value.contentView, queue: .main) { [weak self] _ in
                guard let self = self, let scroll = self.scroll else { return }
                let y = scroll.contentView.bounds.minY
                guard abs(y - self.lastY) > 0.5 else { return }
                self.lastY = y
                let gap = (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY
                self.changed?(gap <= 80)
            }
        }
        deinit { if let token = token { NotificationCenter.default.removeObserver(token) } }
    }
}
struct ChatBottom: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
struct WorkProgressView: View {
    let room: JSONObject
    var openDocument: (JSONObject) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let workflow = room["workflow"] as? JSONObject { WorkflowPanel(workflow: workflow, openDocument: openDocument) }
            if let completion = room["completion"] as? JSONObject {
                Text(completion["summary"] as? String ?? "สรุปผลจากทีม").font(.callout.weight(.medium)).lineLimit(2)
                let checks = completion["checks"] as? [JSONObject] ?? []
                let passed = checks.filter { $0["result"] as? String == "passed" }.count
                DisclosureGroup("ผลตรวจที่ทีมรายงาน \(passed)/\(checks.count)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                                let result = check["result"] as? String ?? "not_run"
                                VStack(alignment: .leading, spacing: 3) {
                                    Label((check["name"] as? String ?? "ผลตรวจ") + " · " + (["passed":"ผ่าน", "failed":"ไม่ผ่าน", "not_run":"ยังไม่ตรวจ"][result] ?? "ยังไม่ตรวจ"), systemImage: result == "passed" ? "checkmark.circle" : result == "failed" ? "xmark.circle" : "clock")
                                    Text(check["evidence"] as? String ?? "").foregroundStyle(OfficeStyle.muted).textSelection(.enabled)
                                }
                            }
                            let remaining = completion["remaining"] as? [String] ?? []
                            ForEach(Array(remaining.enumerated()), id: \.offset) { _, item in Label(item, systemImage: "circle").foregroundStyle(OfficeStyle.warning) }
                            if let review = completion["review"] as? JSONObject {
                                let status = review["status"] as? String ?? ""
                                Text(status == "passed" ? "ผู้ตรวจ: \(review["by"] as? String ?? "ทีม") · ผ่าน" : status == "changes_requested" ? "ผู้ตรวจขอแก้ไข: \(review["evidence"] as? String ?? "")" : status == "not_required" ? "ไม่ต้องตรวจแยก: \(review["reason"] as? String ?? "")" : "ตรวจด้วยตนเอง: \(review["reason"] as? String ?? "")").foregroundStyle(OfficeStyle.muted)
                            } else if room["lastWriter"] as? String != nil {
                                Text("ยังรอผู้ตรวจงานฉบับล่าสุด").foregroundStyle(OfficeStyle.warning)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.frame(maxHeight: 180)
                }.font(.caption)
            } else {
                let running = room["running"] as? JSONObject ?? [:], live = room["live"] as? JSONObject ?? [:]
                let agent = running["agent"] as? String ?? live["agent"] as? String ?? ""
                let assignment = ((room["assignments"] as? JSONObject)?[agent] as? JSONObject)?["assignment"] as? String ?? ""
                let steps = live["steps"] as? [JSONObject] ?? []
                let activity = OfficeStore.activity(step: steps.reversed().first(where: { $0["status"] as? String == "run" }) ?? steps.last, assignment: assignment, coordinator: running["role"] as? String == "coordinator")
                Text(room["status"] as? String == "running" ? activity : "ยังไม่มีสรุปผลตรวจของงานนี้").font(.callout).lineLimit(2).help(activity)
                if room["status"] as? String == "running" { Text("ดำเนินการ \(steps.count) ขั้น · ยังไม่ยืนยันผลสำเร็จ").font(.caption).foregroundStyle(OfficeStyle.muted) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Phase, who owns which task (and its files/dependencies), and the project documents for this room.
struct WorkflowPanel: View {
    let workflow: JSONObject
    let openDocument: (JSONObject) -> Void
    var body: some View {
        let phase = workflow["phase"] as? String ?? ""
        let current = OfficeStore.phases.firstIndex(where: { $0.id == phase }) ?? -1
        let tasks = workflow["tasks"] as? [JSONObject] ?? [], documents = workflow["documents"] as? [JSONObject] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(OfficeStore.phases.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(OfficeStyle.border) }
                    Text(item.label).font(.caption.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? OfficeStyle.accent : index < current ? OfficeStyle.ink : OfficeStyle.muted)
                }
            }.lineLimit(1).minimumScaleFactor(0.8).accessibilityElement(children: .ignore).accessibilityLabel("ขั้นตอนงาน: " + (current >= 0 ? OfficeStore.phases[current].label : "ยังไม่เริ่ม"))
            if !tasks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                            let owner = task["owner"] as? String ?? "", status = task["status"] as? String ?? "pending"
                            let files = task["files"] as? [String] ?? []
                            let blockers = (task["dependsOn"] as? [String] ?? []).filter { id in tasks.first(where: { $0["id"] as? String == id })?["status"] as? String != "done" }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Circle().fill(OfficeStyle.agentColor(owner)).frame(width: 8, height: 8)
                                    Text(owner.capitalized).font(.caption.weight(.semibold))
                                    Text(OfficeStore.taskStatus[status] ?? status).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background((status == "failed" ? OfficeStyle.failure : status == "waiting" ? OfficeStyle.warning : OfficeStyle.accent).opacity(0.1), in: Capsule())
                                        .foregroundStyle(status == "failed" ? OfficeStyle.failure : status == "waiting" ? OfficeStyle.warning : OfficeStyle.accent)
                                    Spacer(minLength: 0)
                                    Text("\(files.count) ไฟล์").font(.caption2).foregroundStyle(OfficeStyle.muted).help(files.joined(separator: "\n"))
                                }
                                Text(plainText(task["assignment"] as? String ?? "")).font(.caption).lineLimit(2).help(task["assignment"] as? String ?? "")
                                if !blockers.isEmpty { Text("รอ: " + blockers.joined(separator: ", ")).font(.caption2).foregroundStyle(OfficeStyle.warning) }
                            }.accessibilityElement(children: .combine)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
            }
            if !documents.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(OfficeStyle.muted)
                    ForEach(Array(documents.enumerated()), id: \.offset) { _, doc in
                        Button(doc["title"] as? String ?? "เอกสาร") { openDocument(doc) }.font(.caption).help(doc["path"] as? String ?? "")
                    }
                }.lineLimit(1)
            }
        }
    }
}
// Markdown text with fenced blocks shown as source; Mermaid is labelled as source, not drawn.
struct DocumentView: View {
    @Environment(\.dismiss) var dismiss
    let document: JSONObject
    var body: some View {
        let path = document["path"] as? String ?? ""
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document["title"] as? String ?? "เอกสาร").font(.headline)
                    Text(path).font(.caption).foregroundStyle(OfficeStyle.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                if !path.isEmpty { Button("แสดงใน Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                Button("ปิด") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(Self.blocks(document["content"] as? String ?? "").enumerated()), id: \.offset) { _, block in
                        if let language = block.language {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(language == "mermaid" ? "แผนภาพ Mermaid (แสดงเป็นซอร์ส)" : language.isEmpty ? "โค้ด" : language).font(.caption.weight(.semibold)).foregroundStyle(OfficeStyle.muted)
                                Text(block.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).background(OfficeStyle.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(OfficeStyle.border))
                            }
                        } else { Text(MessageView.markdown(block.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.padding(.vertical, 4)
            }
        }.padding(20).frame(minWidth: 720, minHeight: 480).background(OfficeStyle.canvas).tint(OfficeStyle.accent).preferredColorScheme(.light)
    }
    static func blocks(_ content: String) -> [(language: String?, text: String)] {
        var result: [(language: String?, text: String)] = [], lines: [String] = [], fence: String?
        func flush() { let text = lines.joined(separator: "\n"); if fence != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append((fence, fence == nil ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text)) }; lines = [] }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if fence == nil { flush(); fence = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased() } else { flush(); fence = nil }
            } else { lines.append(line) }
        }
        flush()
        return result
    }
}

struct MessageView: View {
    let item: JSONObject
    var body: some View {
        let from = item["from"] as? String ?? "system"
        let steps = item["steps"] as? [JSONObject] ?? []
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(from == "user" ? "คุณ" : from == "coordinator" ? "การแบ่งงาน" : from.capitalized).font(.caption.weight(.semibold)).foregroundStyle(from == "user" || from == "system" ? OfficeStyle.muted : OfficeStyle.agentColor(from)); if item["live"] as? Bool == true { ProgressView().controlSize(.mini); Text("กำลังทำงาน").font(.caption2).foregroundStyle(OfficeStyle.muted) } }
            if !steps.isEmpty {
                DisclosureGroup("ขั้นตอนการทำงาน \(steps.count) ขั้น") {
                    VStack(alignment: .leading, spacing: 4) { ForEach(Array(steps.enumerated()), id: \.offset) { _, step in StepView(step: step) } }.padding(.top, 4)
                }.font(.caption)
            }
            if let images = item["images"] as? [JSONObject] {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    if let path = image["path"] as? String, let picture = NSImage(contentsOfFile: path) {
                        Image(nsImage: picture).resizable().scaledToFit().frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityLabel("ภาพแนบ")
                    }
                }
            }
            if let text = item["text"] as? String, !text.isEmpty { Text(Self.markdown(Self.clean(text))).textSelection(.enabled).font(.body) }
            else if item["live"] as? Bool == true, let text = steps.reversed().first(where: { $0["kind"] as? String == "text" })?["body"] as? String, !text.isEmpty { Text(Self.markdown(Self.clean(text))).textSelection(.enabled).font(.body) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(from == "user" ? OfficeStyle.color(0xEFF4F6) : OfficeStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
    static func clean(_ text: String) -> String { text.replacingOccurrences(of: "(?s)\\[\\[NEXT\\s+.*?\\]\\]\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    // Agent replies are Markdown: show bold/code inline, headings as bold lines, keep line breaks.
    static func markdown(_ text: String) -> AttributedString {
        let headings = text.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s+(.+?)\\s*$", with: "**$1**", options: .regularExpression).replacingOccurrences(of: "****", with: "**")
        return (try? AttributedString(markdown: headings, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
struct StepView: View {
    let step: JSONObject
    var body: some View {
        let kind = step["kind"] as? String ?? "tool", title = step["title"] as? String ?? step["name"] as? String ?? kind
        let body = step["body"] as? String ?? step["output"] as? String ?? step["diff"] as? String ?? ""
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(step["status"] as? String == "run" ? "●" : step["status"] as? String == "err" ? "✕" : "✓").foregroundStyle(OfficeStyle.muted); Text(kind == "think" ? "กำลังคิด" : kind == "text" ? "ข้อความ" : title).lineLimit(2) }
            if !body.isEmpty { Text(body.replacingOccurrences(of: "(?s)\\[\\[NEXT\\s+.*?\\]\\]\\s*$", with: "", options: .regularExpression)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}
// Pops up when an agent asks or requests approval: who asks, the full question, an answer box.
struct QuestionView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: OfficeStore
    let question: JSONObject
    @NativeState(wrappedValue: "") private var answer: String
    @NativeState(wrappedValue: false) private var sending: Bool
    @NativeState(wrappedValue: "") private var failure: String
    var key: String { question["key"] as? String ?? "" }
    var body: some View {
        let from = question["from"] as? String ?? "", approve = question["kind"] as? String == "approve"
        let empty = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(OfficeStyle.agentColor(from)).frame(width: 10, height: 10)
                Text(approve ? "\(from.capitalized) ขออนุมัติแผน" : "\(from.capitalized) มีคำถาม").font(.title2.bold())
                Spacer(); Button("ไว้ทีหลัง") { dismiss() }.help("ปิดหน้าต่างนี้ เปิดกลับได้จากปุ่มมุมล่าง")
            }
            ScrollView { Text(MessageView.markdown(MessageView.clean(question["text"] as? String ?? ""))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                .frame(minHeight: 140, maxHeight: 320).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Text(approve ? "ความเห็นเพิ่มเติม (ไม่บังคับ) หรือพิมพ์สิ่งที่อยากให้แก้แผน" : "คำตอบของคุณ").fontWeight(.semibold)
            TextEditor(text: $answer).font(.body).frame(height: 90).border(Color.secondary.opacity(0.3))
            if !failure.isEmpty { Text("ส่งไม่สำเร็จ: \(failure) · ข้อความยังอยู่ ลองส่งอีกครั้งได้").font(.caption).foregroundStyle(OfficeStyle.failure) }
            HStack {
                Button("ปิดงาน", role: .destructive) { submit("api/rooms/\(roomID)/decide", ["action":"cancel"]) }.disabled(sending)
                Spacer()
                if approve {
                    Button("ขอแก้แผน") { submit("api/rooms/\(roomID)/message", ["text":answer]) }.disabled(sending || empty)
                    Button("อนุมัติตามแผน") { submit("api/rooms/\(roomID)/decide", ["action":"approve", "note":answer.trimmingCharacters(in: .whitespacesAndNewlines)]) }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(sending)
                } else {
                    Button("ส่งคำตอบ") { submit("api/rooms/\(roomID)/message", ["text":answer]) }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(sending || empty)
                }
            }.controlSize(.large)
        }.padding(28).frame(width: 660).background(OfficeStyle.canvas).tint(OfficeStyle.accent).preferredColorScheme(.light)
         .onAppear { answer = store.drafts[key] ?? "" }
         .onChange(of: answer) { store.drafts[key] = $0 }
    }
    var roomID: String { String(key.split(separator: ":").first ?? "") }
    func submit(_ path: String, _ body: JSONObject) {
        sending = true; failure = ""
        store.answer(key, path, body) { error in sending = false; if let error = error { failure = error } else { dismiss() } }
    }
}
// CLI-style prompt: one question per page with numbered options (⌘1–⌘9), typed answer, back/next and a final review.
// Closing keeps the draft and page; nothing is ever chosen or sent on the user's behalf.
struct StructuredQuestionView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: OfficeStore
    let question: JSONObject
    @NativeState(wrappedValue: AnswerDraft()) private var draft: AnswerDraft
    @NativeState(wrappedValue: false) private var sending: Bool
    @NativeState(wrappedValue: "") private var failure: String
    var prompt: JSONObject { question["prompt"] as? JSONObject ?? [:] }
    var promptID: String { prompt["id"] as? String ?? "" }
    var items: [JSONObject] { prompt["questions"] as? [JSONObject] ?? [] }
    // A single question submits from its page; several end on a review page.
    var lastPage: Int { items.count > 1 ? items.count : max(0, items.count - 1) }
    var body: some View {
        let from = question["from"] as? String ?? "", page = min(draft.page, lastPage)
        let context = MessageView.clean(question["text"] as? String ?? "")
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(OfficeStyle.agentColor(from)).frame(width: 10, height: 10)
                Text("\(store.agentName(from)) มีคำถาม").font(.title2.bold())
                Spacer(); Button("ไว้ทีหลัง") { dismiss() }.keyboardShortcut(.cancelAction).help("ปิดไว้ก่อน คำตอบที่เลือกยังอยู่ เปิดกลับได้จากปุ่มมุมล่าง")
            }
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        let header = (item["header"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ข้อ \(index + 1)"
                        tab((draft.isAnswered(item) ? "✓ " : "") + header, selected: page == index) { draft.page = index }
                    }
                    tab("ตรวจคำตอบ", selected: page == items.count) { draft.page = items.count }
                }
            }
            if !context.isEmpty {
                DisclosureGroup("รายละเอียดจาก \(store.agentName(from))") {
                    ScrollView { Text(MessageView.markdown(context)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(maxHeight: 160)
                }.font(.callout)
            }
            if page < items.count { questionPage(items[page], number: page + 1) } else { reviewPage }
            if !failure.isEmpty { Text("ส่งไม่สำเร็จ: \(failure) · คำตอบยังอยู่ ลองส่งอีกครั้งได้").font(.caption).foregroundStyle(OfficeStyle.failure) }
            HStack {
                Button("ย้อนกลับ") { draft.page = page - 1 }.disabled(page == 0 || sending).keyboardShortcut("[", modifiers: .command)
                Spacer()
                if page < items.count { Text("ข้อ \(page + 1) จาก \(items.count)").font(.caption).foregroundStyle(OfficeStyle.muted) }
                if page == lastPage {
                    Button(sending ? "กำลังส่ง…" : "ส่งคำตอบ", action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(sending || OfficeStore.answerBody(prompt, draft) == nil)
                } else {
                    Button(page == items.count - 1 ? "ตรวจคำตอบ" : "ถัดไป") { draft.page = page + 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!draft.isAnswered(items[page]))
                }
            }.controlSize(.large)
        }.padding(28).frame(width: 660).background(OfficeStyle.canvas).tint(OfficeStyle.accent).preferredColorScheme(.light)
         .onAppear { draft = store.answerDrafts[promptID] ?? AnswerDraft() }
         .onChange(of: draft) { store.answerDrafts[promptID] = $0 }
    }
    func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? OfficeStyle.accent.opacity(0.12) : OfficeStyle.surface, in: Capsule()).overlay(Capsule().strokeBorder(selected ? OfficeStyle.accent : OfficeStyle.border))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder func questionPage(_ item: JSONObject, number: Int) -> some View {
        let id = item["id"] as? String ?? "", multi = item["multiSelect"] as? Bool == true
        let options = item["options"] as? [JSONObject] ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text(item["question"] as? String ?? "").font(.title3.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if multi { Text("เลือกได้หลายข้อ").font(.caption).foregroundStyle(OfficeStyle.muted) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        let optionID = option["id"] as? String ?? "", on = (draft.selected[id] ?? []).contains(optionID)
                        optionRow(index + 1, option, on: on, multi: multi) { draft.choose(optionID, in: id, multi: multi) }
                    }
                }
            }.frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
            Text(options.isEmpty ? "คำตอบของคุณ" : multi ? "เพิ่มคำตอบเอง (ไม่บังคับ)" : "หรือพิมพ์คำตอบเอง").font(.callout.weight(.semibold)).padding(.top, 4)
            TextEditor(text: Binding(get: { draft.text[id] ?? "" }, set: { draft.type($0, in: id, multi: multi) }))
                .font(.body).frame(height: 64).padding(4).background(OfficeStyle.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(OfficeStyle.border))
                .accessibilityLabel("พิมพ์คำตอบเองสำหรับข้อ \(number)")
        }
    }
    @ViewBuilder func optionRow(_ number: Int, _ option: JSONObject, on: Bool, multi: Bool, action: @escaping () -> Void) -> some View {
        let label = option["label"] as? String ?? "", description = option["description"] as? String ?? ""
        let row = Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")).foregroundStyle(on ? OfficeStyle.accent : OfficeStyle.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(number). \(label)").fontWeight(.medium)
                    if !description.isEmpty { Text(description).font(.callout).foregroundStyle(OfficeStyle.muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }.padding(10).contentShape(Rectangle())
             .background(on ? OfficeStyle.accent.opacity(0.08) : OfficeStyle.surface, in: RoundedRectangle(cornerRadius: 8))
             .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? OfficeStyle.accent : OfficeStyle.border))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityHint(description).accessibilityAddTraits(on ? .isSelected : [])
        if number <= 9 { row.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command).help("⌘\(number)") } else { row }
    }
    var reviewPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ตรวจคำตอบก่อนส่ง").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        let summary = OfficeStore.answerSummary(item, draft)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). " + (item["question"] as? String ?? "")).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                Text(summary.isEmpty ? "ยังไม่ได้ตอบ" : summary).font(.callout).foregroundStyle(summary.isEmpty ? OfficeStyle.warning : OfficeStyle.muted)
                            }
                            Spacer(); Button("แก้") { draft.page = index }.accessibilityLabel("แก้คำตอบข้อ \(index + 1)")
                        }.padding(10).background(OfficeStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
        }
    }
    func submit() {
        guard !sending else { return }
        sending = true; failure = ""
        store.answerDrafts[promptID] = draft
        store.submitAnswers(question) { error in sending = false; if let error = error { failure = error } else { dismiss() } }
    }
}
struct TextSheet: View {
    @Environment(\.dismiss) var dismiss
    let title: String; let text: String
    var body: some View { VStack(alignment: .leading) { HStack { Text(title).font(.headline); Spacer(); Button("ปิด") { dismiss() } }; Divider(); ScrollView { Text(text.isEmpty ? "ไม่มีข้อมูล" : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }.padding(20).frame(minWidth: 720, minHeight: 440).background(OfficeStyle.canvas).tint(OfficeStyle.accent).preferredColorScheme(.light) }
}

struct RoomListView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: OfficeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("ห้องงาน").font(.title2.bold()); Spacer(); Button("ปิด") { dismiss() } }
            if store.rooms.isEmpty { Text("ยังไม่มีห้องงาน").foregroundStyle(OfficeStyle.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { List { ForEach(store.rooms, id: \.roomID) { r in
                Button { store.select(r.roomID); dismiss() } label: { HStack { VStack(alignment: .leading) { Text(r["title"] as? String ?? "ห้องงาน").fontWeight(.semibold); Text(["running":"กำลังทำงาน", "waiting":"รอคุณ", "done":"เสร็จ", "idle":"ว่าง"][r["status"] as? String ?? ""] ?? "").font(.caption).foregroundStyle(OfficeStyle.muted) }; Spacer(); if store.selectedID == r.roomID { Image(systemName: "checkmark") } } }.buttonStyle(.plain).padding(5)
            } } }
        }.padding(24).frame(width: 600, height: 480).background(OfficeStyle.canvas).tint(OfficeStyle.accent).preferredColorScheme(.light)
    }
}
struct NewRoomView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: OfficeStore
    var initialTask = ""
    var initialImages: [DraftImage] = []
    var onCreated: () -> Void = {}
    @NativeState(wrappedValue: "") private var task: String
    @NativeState(wrappedValue: []) private var images: [DraftImage]
    @NativeState(wrappedValue: []) private var dirs: [String]
    @NativeState(wrappedValue: "") private var typedPath: String
    @NativeState(wrappedValue: []) private var skills: Set<String>
    @NativeState(wrappedValue: false) private var showSkillPicker: Bool
    @NativeState(wrappedValue: "auto") private var lead: String
    @NativeState(wrappedValue: false) private var submitting: Bool
    @NativeState(wrappedValue: nil) private var sendError: String?
    var canCreate: Bool { (!task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && !dirs.isEmpty && (skills.isEmpty || !store.skillsLoading) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("เริ่มงานกับทีม").font(.title2.bold())
                    Text("เล่าเป้าหมาย แนบภาพได้ แล้วทีมจะบรีฟและแบ่งงานให้").font(.callout).foregroundStyle(OfficeStyle.muted)
                }
                Spacer()
                Button("ยกเลิก") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("1  อยากให้ทีมช่วยอะไร", systemImage: "text.bubble").font(.headline)
                        PromptInput(text: $task, images: $images, title: "เช่น ปรับหน้าเข้าสู่ระบบให้ใช้งานง่ายขึ้น…", height: 140, autofocus: true, submit: create)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Label("2  ทำงานในโปรเจกต์ไหน", systemImage: "folder").font(.headline); Spacer(); Button("เลือกโฟลเดอร์…", action: pickFolders) }
                        if dirs.isEmpty {
                            Text("เลือกโฟลเดอร์ที่ทีมจะอ่านหรือแก้ไขไฟล์").foregroundStyle(OfficeStyle.muted).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                        ForEach(dirs, id: \.self) { dir in
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").foregroundStyle(OfficeStyle.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text(URL(fileURLWithPath: dir).lastPathComponent).fontWeight(.medium); if dirs.first == dir { Text("โปรเจกต์หลัก").font(.caption2).foregroundStyle(OfficeStyle.muted) } }
                                    Text(dir).font(.caption).foregroundStyle(OfficeStyle.muted).lineLimit(1).truncationMode(.middle).help(dir)
                                }
                                Spacer(minLength: 4)
                                if dirs.first != dir { Button("ตั้งเป็นหลัก") { dirs.removeAll { $0 == dir }; dirs.insert(dir, at: 0) }.font(.caption) }
                                Button { dirs.removeAll { $0 == dir } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("นำโปรเจกต์ออก")
                            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                        let recent = (store.settings["recentDirs"] as? [String] ?? []).filter { !dirs.contains($0) }
                        if !recent.isEmpty {
                            ScrollView(.horizontal) { HStack { Text("ล่าสุด").font(.caption).foregroundStyle(OfficeStyle.muted); ForEach(Array(recent.prefix(4)), id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { dirs.append(path) }.font(.caption).help(path) } } }
                        }
                        DisclosureGroup("พิมพ์ตำแหน่งโฟลเดอร์เอง") { HStack { TextField("เช่น ~/Documents/my-project", text: $typedPath).textFieldStyle(.roundedBorder).onSubmit(addTyped); Button("เพิ่ม", action: addTyped) }.padding(.top, 6) }.font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("3  สกิลที่ต้องใช้", systemImage: "square.stack.3d.up").font(.headline)
                                Text(skills.isEmpty ? "ไม่บังคับ · เลือกเพิ่มเมื่ออยากให้ทีมใช้สกิลเฉพาะ" : "เลือกแล้ว \(skills.count) สกิล").font(.caption).foregroundStyle(OfficeStyle.muted)
                            }
                            Spacer()
                            Button(skills.isEmpty ? "เลือกสกิล…" : "เปลี่ยนสกิล…") { showSkillPicker = true }
                                .popover(isPresented: $showSkillPicker, arrowEdge: .bottom) {
                                    SkillPickerView(store: store, selected: $skills, reload: reloadSkills)
                                }
                        }
                        if !skills.isEmpty {
                            Text(store.skillCatalog.filter { skills.contains($0.roomID) }.map { $0["name"] as? String ?? "" }.joined(separator: " · "))
                                .font(.callout).foregroundStyle(OfficeStyle.accent).lineLimit(2)
                        }
                        if let error = store.skillsError { Text("โหลดสกิลไม่สำเร็จ: " + error).font(.caption).foregroundStyle(OfficeStyle.failure) }
                    }.officeCard()
                    DisclosureGroup("กำหนดผู้เริ่มงานเอง") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("ผู้เริ่มรับผิดชอบ", selection: $lead) { Text("ให้ทีมเลือก (แนะนำ)").tag("auto"); ForEach(store.agentIDs, id: \.self) { Text(store.agentName($0)).tag($0) } }
                            Text("ทีมจะสรุปโจทย์และแจ้งผู้รับผิดชอบก่อนเริ่มงาน").font(.caption).foregroundStyle(OfficeStyle.muted)
                        }.padding(.top, 8)
                    }.font(.callout).padding(14).background(OfficeStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                }.padding(22)
            }.disabled(submitting)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let error = sendError { Text(error).foregroundStyle(OfficeStyle.failure) }
                    else { Text(dirs.isEmpty ? "เลือกโปรเจกต์ก่อนเริ่มงาน" : canCreate ? "พร้อมส่งโจทย์ให้ทีมบรีฟ" : "ใส่โจทย์หรือแนบรูปเพื่อเริ่มงาน").foregroundStyle(OfficeStyle.muted) }
                    Text("ตรวจแผนก่อนอนุมัติให้ทีมแก้ไขไฟล์").foregroundStyle(OfficeStyle.muted)
                }.font(.caption)
                Spacer()
                if submitting { ProgressView().controlSize(.small) }
                Button(submitting ? "กำลังส่ง…" : "เริ่มบรีฟงาน", action: create).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command).disabled(submitting || !canCreate)
            }.padding(18)
        }.frame(width: 700, height: 690).background(OfficeStyle.canvas).tint(OfficeStyle.accent).preferredColorScheme(.light).onAppear {
            dirs = store.settings["lastDirs"] as? [String] ?? []
            if task.isEmpty { task = initialTask }; if images.isEmpty { images = initialImages }
            reloadSkills()
        }
        .onChange(of: dirs) { _ in reloadSkills() }
    }
    func reloadSkills() {
        store.loadSkills(dirs: dirs) { catalog in skills.formIntersection(Set(catalog.compactMap { $0["id"] as? String })) }
    }
    func pickFolders() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true; p.prompt = "ใช้โปรเจกต์นี้"
        if let dir = dirs.first { p.directoryURL = URL(fileURLWithPath: dir) }
        if p.runModal() == .OK { for url in p.urls where !dirs.contains(url.path) { dirs.append(url.path) } }
    }
    func addTyped() { let p = (typedPath as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines); if !p.isEmpty && !dirs.contains(p) { dirs.append(p); typedPath = "" } }
    func create() {
        guard canCreate, !submitting else { return }
        submitting = true; sendError = nil
        store.uploadImages(images) { result in
            switch result {
            case .failure(let error): submitting = false; sendError = error.localizedDescription
            case .success(let files):
                store.request("api/rooms", method: "POST", body: ["task":task, "dirs":dirs, "skills":skills.sorted(), "lead":lead, "images":files.map { $0["id"] as? String ?? "" }]) { result in
                    submitting = false
                    switch result { case .success(let r): store.select(r["id"] as? String); onCreated(); dismiss(); case .failure(let e): sendError = e.localizedDescription }
                }
            }
        }
    }
}
struct SkillPickerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: OfficeStore
    @Binding var selected: Set<String>
    var reload: () -> Void
    @NativeState(wrappedValue: "") private var search: String
    var filtered: [JSONObject] { Self.matching(store.skillCatalog, search: search) }
    static func matching(_ catalog: [JSONObject], search: String) -> [JSONObject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? catalog : catalog.filter { item in
            ["name", "description", "source"].compactMap { item[$0] as? String }.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("เลือกสกิล").font(.title3.weight(.semibold)); Spacer(); Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("อ่านรายการสกิลใหม่").accessibilityLabel("อ่านรายการสกิลใหม่").disabled(store.skillsLoading) }
                Text("สกิลส่วนตัวและสกิลในโปรเจกต์ · เลือกได้หลายรายการ").font(.caption).foregroundStyle(OfficeStyle.muted)
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(OfficeStyle.muted); TextField("ค้นหาชื่อหรือสิ่งที่สกิลช่วยทำ…", text: $search).textFieldStyle(.plain).accessibilityLabel("ค้นหาสกิล") }.padding(10).background(OfficeStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
            }.padding(16)
            Divider()
            if store.skillsLoading { ProgressView("กำลังอ่านสกิลที่ติดตั้ง…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error = store.skillsError {
                VStack(spacing: 12) { Text("อ่านรายการสกิลไม่ได้").font(.headline); Text(error).font(.callout).foregroundStyle(OfficeStyle.muted); Button("ลองใหม่", action: reload) }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 8) { Text(search.isEmpty ? "ยังไม่พบสกิลที่ติดตั้ง" : "ไม่พบสกิลที่ตรงกับคำค้น").font(.headline); Text(search.isEmpty ? "ใช้สกิลส่วนตัวใน .agents/skills, .claude/skills หรือ .codex/skills หรือสกิลในโปรเจกต์ที่เลือก" : "ลองค้นด้วยชื่อหรือหน้าที่ เช่น frontend หรือทดสอบ").font(.callout).foregroundStyle(OfficeStyle.muted).multilineTextAlignment(.center) }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.roomID) { item in
                            Toggle(isOn: Binding(get: { selected.contains(item.roomID) }, set: { enabled in if enabled { selected.insert(item.roomID) } else { selected.remove(item.roomID) } })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(item["name"] as? String ?? "").font(.callout.weight(.semibold)); Spacer(); Text(item["source"] as? String ?? "").font(.caption2).foregroundStyle(OfficeStyle.muted) }
                                    if let description = item["description"] as? String, !description.isEmpty { Text(description).font(.caption).foregroundStyle(OfficeStyle.muted).lineLimit(2) }
                                }
                            }.toggleStyle(.checkbox).accessibilityLabel(Text(item["name"] as? String ?? "")).accessibilityHint(Text(item["description"] as? String ?? "")).padding(.vertical, 12).padding(.horizontal, 16).help(item["path"] as? String ?? "")
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            Divider()
            HStack { Text("เลือกแล้ว \(selected.count) สกิล").font(.callout).foregroundStyle(OfficeStyle.muted); if !selected.isEmpty { Button("ล้างที่เลือก") { selected.removeAll() }.buttonStyle(.borderless) }; Spacer(); Button("เสร็จ") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }.padding(14)
        }.frame(width: 540, height: 450).background(OfficeStyle.surface).tint(OfficeStyle.accent).preferredColorScheme(.light)
    }
}

struct AgentSettings {
    var models = ""; var model = ""; var effort = ""; var maxEffort = ""; var efforts: [String] = []; var enabled = true; var original: JSONObject = [:]
    init(_ data: JSONObject) { original = data; models = (data["models"] as? [String] ?? []).joined(separator: ", "); model = data["model"] as? String ?? ""; effort = data["effort"] as? String ?? ""; maxEffort = data["maxEffort"] as? String ?? ""; efforts = data["efforts"] as? [String] ?? []; enabled = data["enabled"] as? Bool ?? true }
    var json: JSONObject { var value = original; value["models"] = models.split(separator:",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }; value["model"] = model; value["effort"] = effort; value["maxEffort"] = maxEffort; value["enabled"] = enabled; return value }
}
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: OfficeStore
    @NativeState(wrappedValue: [:]) private var policies: [String: AgentSettings]
    @NativeState(wrappedValue: "") private var dispatcherAgent: String
    @NativeState(wrappedValue: "") private var dispatcherModel: String
    @NativeState(wrappedValue: "") private var dispatcherEffort: String
    @NativeState(wrappedValue: "") private var guide: String
    @NativeState(wrappedValue: "") private var maxTurns: String
    @NativeState(wrappedValue: "") private var cooldown: String
    @NativeState(wrappedValue: "") private var timeout: String
    @NativeState(wrappedValue: "AI ในเครื่อง") private var section: String
    @NativeState(wrappedValue: []) private var entries: [JSONObject]
    @NativeState(wrappedValue: "") private var newID: String
    @NativeState(wrappedValue: "") private var newCommand: String
    @NativeState(wrappedValue: false) private var discovering: Bool
    var ids: [String] { Array(Set(store.agents.keys).union(policies.keys)).sorted() }
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("ตั้งค่า").font(.title2.weight(.semibold)); Text("ข้อมูลจาก CLI แยกจากข้อจำกัดที่คุณกำหนด").font(.callout).foregroundStyle(OfficeStyle.muted) }; Spacer(); Button("ยกเลิก") { dismiss() } }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["AI ในเครื่อง", "การเลือกตามงาน", "ขอบเขตการทำงาน"], id: \.self) { title in
                        Button { section = title } label: { Text(title).font(.callout.weight(section == title ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(section == title ? OfficeStyle.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).foregroundStyle(section == title ? OfficeStyle.accent : OfficeStyle.muted)
                    }
                    Spacer()
                }.padding(12).frame(width: 170).background(OfficeStyle.canvas)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if section == "AI ในเครื่อง" {
                            HStack { Text("AI ในเครื่อง").font(.title3.weight(.semibold)); Spacer(); if discovering { ProgressView().controlSize(.small) }; Button("ตรวจหาใหม่") { discover() }.disabled(discovering) }
                            if ids.isEmpty { Text("ยังไม่พบ CLI · ตรวจ PATH หรือเพิ่มตัวเชื่อมด้านล่าง").foregroundStyle(OfficeStyle.muted) }
                            ForEach(ids, id: \.self) { id in agentSection(id) }
                            DisclosureGroup("เพิ่มตัวเชื่อม CLI") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("เลือกไฟล์ตัวเชื่อมที่รองรับ Office Room (office-jsonl) ไม่ใช่ CLI ที่ยังไม่มีตัวเชื่อม").font(.caption).foregroundStyle(OfficeStyle.muted)
                                    TextField("ชื่อ ID เช่น my-agent", text: $newID).textFieldStyle(.roundedBorder)
                                    TextField("ตำแหน่งไฟล์ตัวเชื่อมแบบเต็ม", text: $newCommand).textFieldStyle(.roundedBorder)
                                    Button("เพิ่มในรายการ") { entries.append(["id":newID,"displayName":newID,"command":newCommand,"adapter":"office-jsonl"]); policies[newID] = AgentSettings([:]); newID = ""; newCommand = "" }.disabled(newID.isEmpty || newCommand.isEmpty)
                                    ForEach(entries.compactMap { $0["id"] as? String }, id: \.self) { id in HStack { Text(id); Spacer(); Button("นำออก") { entries.removeAll { $0["id"] as? String == id }; policies.removeValue(forKey: id) } } }
                                }.padding(.top, 10)
                            }
                        } else if section == "การเลือกตามงาน" {
                            Text("เลือกตามงานโดยอัตโนมัติ").font(.title3.weight(.semibold))
                            Text("ทีมเลือกผู้รับผิดชอบ โมเดล และ effort จาก catalog บริบท และข้อจำกัดที่คุณตั้ง ไม่มีลำดับตามยี่ห้อ และไม่ส่งงานเดียวกันให้ทุกตัวแข่งกัน").foregroundStyle(OfficeStyle.muted)
                            Text("แนวทางเพิ่มเติมสำหรับทีม").font(.headline)
                            TextEditor(text: $guide).frame(height: 130).officeCard()
                            DisclosureGroup("ผู้บรีฟงาน (ไม่บังคับ)") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Picker("CLI", selection: $dispatcherAgent) { Text("อัตโนมัติ · เริ่มอย่างเป็นกลาง").tag(""); ForEach(ids, id: \.self) { Text(store.agentName($0)).tag($0) } }
                                    TextField("Model ของผู้บรีฟ (ว่าง = ค่าเริ่มต้น CLI)", text: $dispatcherModel)
                                    TextField("Effort ของผู้บรีฟ (ว่าง = ค่าเริ่มต้น CLI)", text: $dispatcherEffort)
                                    Text("ค่าเริ่มต้นต้องอยู่ในขอบเขตที่ยืนยันได้ หาก CLI ไม่ส่ง default effort และมีเพดาน ให้ระบุค่าที่รองรับที่นี่").font(.caption).foregroundStyle(OfficeStyle.muted)
                                }.textFieldStyle(.roundedBorder).padding(.top, 12)
                            }
                            if store.settings["legacyRouting"] is JSONObject { Text("แนวทางและ dispatcher รุ่นก่อนยังเก็บไว้ใน legacyRouting ค่าใหม่ใช้การเลือกตามงาน").font(.caption).foregroundStyle(OfficeStyle.muted) }
                        } else {
                            Text("ขอบเขตการทำงาน").font(.title3.weight(.semibold))
                            Text("ทีมขออนุมัติก่อนแก้ไฟล์ และพัก CLI ที่ติด limit เพื่อให้สมาชิกที่พร้อมรับช่วง").foregroundStyle(OfficeStyle.muted)
                            Form { TextField("งบการส่งงาน (0 = ไม่จำกัดรอบ)", text: $maxTurns); TextField("พักเมื่อไม่ทราบเวลา reset (นาที)", text: $cooldown); TextField("Timeout ต่อรอบ (นาที)", text: $timeout) }.formStyle(.columns)
                            Text("จำนวนรอบเป็นงบที่คุณกำหนด ไม่ใช่เกณฑ์ว่าคำตอบดีพอแล้ว ทีมต้องรายงานหลักฐานก่อนจบงาน").font(.caption).foregroundStyle(OfficeStyle.muted)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack { Text("การมีรายชื่อโมเดลไม่ยืนยันสิทธิ์เรียกใช้ทุกตัว").font(.caption).foregroundStyle(OfficeStyle.muted); Spacer(); Button("บันทึก", action: save).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command) }.padding(18)
        }.frame(width: 900, height: 680).background(OfficeStyle.surface).tint(OfficeStyle.accent).preferredColorScheme(.light).onAppear(perform: load)
        .alert("เกิดข้อผิดพลาด", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("ตกลง") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    func binding(_ id: String) -> Binding<AgentSettings> { Binding(get: { policies[id] ?? AgentSettings([:]) }, set: { policies[id] = $0 }) }
    func agentSection(_ id: String) -> some View {
        let info = store.agents[id] as? JSONObject ?? [:]
        let models = info["models"] as? [JSONObject] ?? []
        let value = binding(id)
        let efforts = Array(NSOrderedSet(array: models.flatMap { (model: JSONObject) -> [String] in model["supportedEfforts"] as? [String] ?? [] } + (policies[id]?.efforts ?? []))) as? [String] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.agentName(id)).font(.headline); Spacer(); Toggle("เปิดใช้งาน", isOn: value.enabled).toggleStyle(.switch).controlSize(.small) }
            Text([info["version"] as? String ?? "", info["authState"] as? String == "loggedIn" ? "ลงชื่อเข้าใช้แล้ว" : info["installed"] as? Bool == false ? "ไม่พบในเครื่อง" : "ยังไม่ยืนยันการลงชื่อเข้าใช้"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(OfficeStyle.muted)
            if let error = info["discoveryError"] as? String { Text(error).font(.caption).foregroundStyle(OfficeStyle.warning) }
            if info["supported"] as? Bool == false { Text("พบ CLI แต่ยังไม่มีตัวเชื่อมรองรับ").font(.caption).foregroundStyle(OfficeStyle.warning) }
            Form {
                TextField("Model ที่อนุญาต (ว่าง = ทั้งหมด)", text: value.models)
                Picker("Effort สูงสุด", selection: value.maxEffort) { Text("ตามงาน · ไม่กำหนดเพดาน").tag(""); ForEach(efforts, id: \.self) { Text($0).tag($0) } }
            }.formStyle(.columns)
            DisclosureGroup("โมเดลที่ CLI รายงาน (\(models.count))") {
                VStack(alignment: .leading, spacing: 12) { ForEach(models, id: \.modelID) { model in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model["displayName"] as? String ?? model.modelID).font(.callout.weight(.medium))
                        Text((model["supportedEfforts"] as? [String] ?? []).isEmpty ? "CLI ไม่ได้ส่งรายการ effort · ใช้ default เมื่อข้อจำกัดอนุญาต" : (model["supportedEfforts"] as? [String] ?? []).joined(separator: " · ")).font(.caption).foregroundStyle(OfficeStyle.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } }.padding(.top, 8)
            }.font(.callout)
        }.officeCard()
    }
    func discover() { discovering = true; store.request("api/agents/discover", method: "POST", body: [:]) { result in discovering = false; switch result { case .success(let agents): store.agents = agents; case .failure(let error): store.error = error.localizedDescription } } }
    func load() {
        let s = store.settings, agents = s["agents"] as? JSONObject ?? [:], d = s["dispatcher"] as? JSONObject ?? [:]
        for id in Set(store.agents.keys).union(agents.keys) { policies[id] = AgentSettings(agents[id] as? JSONObject ?? [:]) }
        dispatcherAgent = d["agent"] as? String ?? ""; dispatcherModel = d["model"] as? String ?? ""; dispatcherEffort = d["effort"] as? String ?? ""
        guide = s["leadGuide"] as? String ?? ""; maxTurns = "\(s["maxAutoTurns"] ?? 0)"; cooldown = "\(s["cooldownMin"] ?? 60)"; timeout = "\(s["timeoutMin"] ?? 40)"; entries = s["cliEntries"] as? [JSONObject] ?? []
    }
    func save() {
        guard let turns = Int(maxTurns), let cool = Int(cooldown), let limit = Int(timeout), turns >= 0, cool > 0, limit > 0 else { store.error = "งบการส่งงานต้องไม่ติดลบ และเวลาต้องมากกว่า 0"; return }
        var s = store.settings; s["schemaVersion"] = 2; s["agents"] = policies.mapValues { $0.json }; s["dispatcher"] = ["mode":"auto", "agent":dispatcherAgent, "model":dispatcherModel, "effort":dispatcherEffort]; s["leadGuide"] = guide; s["maxAutoTurns"] = turns; s["cooldownMin"] = cool; s["timeoutMin"] = limit; s["cliEntries"] = entries
        store.perform("api/settings", body: s) { store.settings = $0; dismiss() }
    }
}

struct UsageCard: View {
    let agent: String
    // Where the reading came from; local readings are free, provider calls are rate limited.
    static func sourceLabel(_ source: String?) -> String {
        switch source {
        case "Claude CLI": return "จากงานล่าสุด"
        case "Codex session file": return "จากไฟล์ของ Codex"
        case "Claude usage service", "Codex app-server": return "ถามผู้ให้บริการ"
        default: return source ?? "ข้อมูลครั้งก่อน"
        }
    }
    let info: JSONObject
    var refresh: () -> Void = {}
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date.timeIntervalSince1970 * 1000
            let resting = (info["restingUntil"] as? Double ?? 0) > now
            let installed = info["installed"] as? Bool
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Circle().fill(OfficeStyle.agentColor(agent)).frame(width: 8, height: 8)
                    Text(info["displayName"] as? String ?? agent.capitalized).fontWeight(.semibold)
                    Text(installed == nil ? "กำลังเชื่อมต่อ" : installed == false ? "ไม่ได้ติดตั้ง" : resting ? "พักชั่วคราว" : info["supported"] as? Bool == false ? "ยังไม่รองรับ" : info["authState"] as? String == "loggedOut" ? "ต้อง login" : info["ready"] as? Bool == false ? "ยังไม่พร้อม" : "พร้อม").foregroundStyle(OfficeStyle.muted)
                    Spacer(minLength: 4)
                    if info["refreshing"] as? Bool == true { ProgressView().controlSize(.mini) }
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("อัปเดตการใช้งานใหม่").disabled(info["refreshing"] as? Bool == true)
                }.font(.caption)
                let windows = info["windows"] as? [JSONObject] ?? []
                if windows.isEmpty { Text("ยังไม่มีข้อมูลการใช้งาน").font(.caption2).foregroundStyle(OfficeStyle.muted) }
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    let reset = window["resetsAt"] as? Double ?? 0
                    let used = window["used"] as? Double ?? 0
                    HStack(spacing: 6) {
                        Text(window["key"] as? String ?? "").frame(width: 22, alignment: .leading)
                        ProgressView(value: min(100, max(0, used)), total: 100).tint(used >= 90 ? .red : OfficeStyle.accent).frame(width: 45)
                        Text("ใช้แล้ว \(Int(used))%").monospacedDigit().frame(width: 64, alignment: .trailing)
                        if reset > 0 { Text("รีเซ็ต " + Date(timeIntervalSince1970: reset / 1000).formatted(.dateTime.weekday(.abbreviated).hour().minute())).lineLimit(1) }
                    }.font(.caption2).foregroundStyle(OfficeStyle.muted)
                }
                if let updated = info["updatedAt"] as? Double {
                    Text(Self.sourceLabel(info["source"] as? String) + " · อัปเดต " + Date(timeIntervalSince1970: updated / 1000).formatted(.dateTime.hour().minute()) + (now - updated > 600000 ? " · ข้อมูลเก่า" : "")).font(.caption2).foregroundStyle(OfficeStyle.muted).lineLimit(1)
                }
                if let error = info["refreshError"] as? String { Text(error + " · แสดงค่าครั้งก่อน").font(.caption2).foregroundStyle(OfficeStyle.warning).lineLimit(2) }
                if let error = info["discoveryError"] as? String { Text(error).font(.caption2).foregroundStyle(OfficeStyle.warning).lineLimit(2) }
            }.officeCard().frame(maxWidth: 340, alignment: .leading)
        }
    }
}
