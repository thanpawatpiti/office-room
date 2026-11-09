import Cocoa
import Combine

typealias JSONObject = [String: Any]
func agentAccent(_ id: String) -> UInt32 {
    let palette: [UInt32] = [0x66559A, 0x176C65, 0x9D542D, 0x385F91, 0x7D5F2C]
    return palette[id.utf8.reduce(0) { ($0 + Int($1)) % palette.count }]
}

// Unsent answers for one structured prompt, plus the page the user was on.
struct AnswerDraft: Equatable {
    var page = 0
    var selected: [String: [String]] = [:]
    var text: [String: String] = [:]
    // Single choice behaves like CLI radio buttons: an option replaces typed text, typed text replaces the option.
    mutating func choose(_ option: String, in question: String, multi: Bool) {
        var current = selected[question] ?? []
        if !multi { current = [option]; text[question] = "" }
        else if let index = current.firstIndex(of: option) { current.remove(at: index) } else { current.append(option) }
        selected[question] = current
    }
    mutating func type(_ value: String, in question: String, multi: Bool) {
        text[question] = value
        if !multi && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { selected[question] = [] }
    }
    func isAnswered(_ q: JSONObject) -> Bool {
        let id = q["id"] as? String ?? "", options = Set((q["options"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String })
        return (selected[id] ?? []).contains(where: options.contains) || !(text[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class EventStreamParser {
    private var buffer = Data()
    private var lines: [String] = []
    func append(_ data: Data) -> [JSONObject] {
        buffer.append(data)
        var events: [JSONObject] = []
        while let newline = buffer.firstIndex(of: 10) {
            var lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if lineData.last == 13 { lineData = lineData.dropLast() }
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if line.isEmpty {
                let text = lines.joined(separator: "\n"); lines.removeAll(keepingCapacity: true)
                if let bytes = text.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: bytes) as? JSONObject { events.append(event) }
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5)); if value.first == " " { value.removeFirst() }; lines.append(value)
            }
        }
        return events
    }
}

final class EventConnection: NSObject, URLSessionDataDelegate {
    private let url: URL
    private var session: URLSession?
    private var parser = EventStreamParser()
    private var stopped = false
    var onEvent: ((JSONObject) -> Void)?
    var onDisconnect: (() -> Void)?
    init(url: URL) { self.url = url }
    func start() {
        guard !stopped else { return }
        parser = EventStreamParser()
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue); session = s
        s.dataTask(with: url).resume()
    }
    func stop() { stopped = true; session?.invalidateAndCancel(); session = nil }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for event in parser.append(data) { DispatchQueue.main.async { self.onEvent?(event) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            self.onDisconnect?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
        }
    }
}

final class OfficeStore: ObservableObject {
    @Published var rooms: [JSONObject] = []
    @Published var room: JSONObject?
    @Published var agents: JSONObject = [:]
    @Published var settings: JSONObject = [:]
    @Published var skillCatalog: [JSONObject] = []
    @Published var skillsLoading = false
    @Published var skillsError: String?
    @Published var selectedID: String?
    @Published var notice = "กำลังเชื่อมต่อ…"
    @Published var error: String?
    private let base: URL
    private var stream: EventConnection?
    private var selectionRequest = 0
    private var roomVersion = 0
    private var skillsRequest = 0
    private var skillsDirs: [String]?
    var isRunning: Bool { room?["running"] is JSONObject }
    var agentIDs: [String] { agents.keys.sorted().filter { let info = agents[$0] as? JSONObject ?? [:]; return info["installed"] as? Bool != false && info["supported"] as? Bool != false && info["duplicateOf"] as? String == nil } }
    func agentName(_ id: String) -> String { (agents[id] as? JSONObject)?["displayName"] as? String ?? id.capitalized }
    // Prompts already popped up (one popup per question) and unsent answers, keyed by question.
    var shownQuestions: Set<String> = []
    var drafts: [String: String] = [:]
    var answerDrafts: [String: AnswerDraft] = [:]
    init(base: URL) { self.base = base }

    func loadSkills(dirs: [String], done: (([JSONObject]) -> Void)? = nil) {
        if skillsLoading && skillsDirs == dirs { return }
        skillsRequest += 1; let requestID = skillsRequest; skillsDirs = dirs
        skillsLoading = true; skillsError = nil
        request("api/skills", method: "POST", body: ["dirs": dirs]) { result in
            guard self.skillsRequest == requestID else { return }
            self.skillsLoading = false
            switch result {
            case .success(let data): self.skillCatalog = data["skills"] as? [JSONObject] ?? []; done?(self.skillCatalog)
            case .failure(let error): self.skillsError = error.localizedDescription
            }
        }
    }

    // The room waits on an agent's question or approval request, and that agent's message is the latest one.
    // (A stop leaves a system message last and an answer leaves a user message last, so neither pops up.)
    // Structured questions come first and stay open while the room runs (a native Codex request pauses inside its turn).
    func pendingQuestion() -> JSONObject? {
        if let r = room, (r["waiting"] as? JSONObject)?["kind"] as? String != "approve" || r["status"] as? String != "waiting",
           let prompt = (r["questions"] as? [JSONObject])?.first(where: { $0["status"] as? String == "pending" && !($0["questions"] as? [JSONObject] ?? []).isEmpty }),
           let id = prompt["id"] as? String {
            let from = prompt["from"] as? String ?? ""
            // Room questions keep their background in the asker's message; a native request has none.
            let context = prompt["source"] as? String == "room" ? ((r["messages"] as? [JSONObject])?.last(where: { $0["from"] as? String == from })?["text"] as? String ?? "") : ""
            return ["key": "\(r["id"] as? String ?? ""):\(id):questions", "kind": "questions", "from": from, "prompt": prompt, "text": context]
        }
        guard let r = room, r["status"] as? String == "waiting", let w = r["waiting"] as? JSONObject,
              let kind = w["kind"] as? String, ["ask", "approve"].contains(kind),
              let from = w["from"] as? String, let messages = r["messages"] as? [JSONObject],
              // An approval may be followed by the server's own note ("asked to edit files without approval").
              let last = kind == "approve" ? messages.last(where: { $0["from"] as? String != "system" }) : messages.last,
              last["from"] as? String == from else { return nil }
        return ["key": "\(r["id"] as? String ?? ""):\(last["id"] as? String ?? ""):\(kind)", "kind": kind, "from": from, "text": last["text"] as? String ?? ""]
    }

    func request(_ path: String, method: String = "GET", body: JSONObject? = nil, completion: @escaping (Result<JSONObject, Error>) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path)); req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "x-office"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body { do { req.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { completion(.failure(error)); return } }
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result<JSONObject, Error>
            if let error = error { result = .failure(error) }
            else if let data = data, let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
                if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                    result = .failure(NSError(domain: "Office Room", code: code, userInfo: [NSLocalizedDescriptionKey: object["error"] as? String ?? "เกิดข้อผิดพลาด"]))
                } else { result = .success(object) }
            } else { result = .failure(NSError(domain: "Office Room", code: 0, userInfo: [NSLocalizedDescriptionKey: "ข้อมูลตอบกลับไม่ถูกต้อง"])) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
    func perform(_ path: String, method: String = "POST", body: JSONObject = [:], success: ((JSONObject) -> Void)? = nil) {
        request(path, method: method, body: method == "GET" || method == "DELETE" ? nil : body) { result in
            switch result { case .success(let data): success?(data); case .failure(let e): self.error = e.localizedDescription }
        }
    }
    // Sends an answer/decision from the question popup; the draft is dropped only once the server accepted it.
    func answer(_ key: String, _ path: String, _ body: JSONObject, done: @escaping (String?) -> Void) {
        request(path, method: "POST", body: body) { result in
            switch result { case .success: self.drafts[key] = nil; done(nil); case .failure(let e): done(e.localizedDescription) }
        }
    }
    // Structured answers: nothing is sent until every question has a choice or typed text; the draft survives failures.
    func submitAnswers(_ question: JSONObject, done: @escaping (String?) -> Void) {
        let key = question["key"] as? String ?? "", prompt = question["prompt"] as? JSONObject ?? [:], id = prompt["id"] as? String ?? ""
        guard let answers = Self.answerBody(prompt, answerDrafts[id] ?? AnswerDraft()) else { done("กรุณาตอบทุกข้อ"); return }
        answer(key, "api/rooms/\(key.split(separator: ":").first ?? "")/answer", ["questionId": id, "answers": answers]) { error in
            if error == nil { self.answerDrafts[id] = nil }
            done(error)
        }
    }
    static func answerBody(_ prompt: JSONObject, _ draft: AnswerDraft) -> JSONObject? {
        var body: JSONObject = [:]
        for q in prompt["questions"] as? [JSONObject] ?? [] {
            guard let id = q["id"] as? String, draft.isAnswered(q) else { return nil }
            // Option order, not click order, so an identical retry sends identical JSON.
            let chosen = Set(draft.selected[id] ?? [])
            body[id] = ["selected": (q["options"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String }.filter(chosen.contains), "text": draft.text[id] ?? ""] as JSONObject
        }
        return body.isEmpty ? nil : body
    }
    static func answerSummary(_ q: JSONObject, _ draft: AnswerDraft) -> String {
        let id = q["id"] as? String ?? "", chosen = Set(draft.selected[id] ?? [])
        let labels = (q["options"] as? [JSONObject] ?? []).filter { chosen.contains($0["id"] as? String ?? "") }.compactMap { $0["label"] as? String }
        return (labels + [(draft.text[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: ", ")
    }
    func connect() {
        refresh()
        stream?.stop()
        let connection = EventConnection(url: base.appendingPathComponent("api/events")); stream = connection
        connection.onEvent = { [weak self] in self?.receive($0) }
        connection.onDisconnect = { [weak self] in self?.notice = "กำลังเชื่อมต่อใหม่…"; self?.refresh() }
        connection.start()
    }
    func stop() { stream?.stop(); stream = nil }
    func refresh() {
        request("api/state") { result in
            switch result {
            case .failure(let e): self.notice = "เชื่อมต่อไม่ได้: \(e.localizedDescription)"
            case .success(let data):
                self.notice = ""; self.rooms = data["rooms"] as? [JSONObject] ?? []; self.settings = data["settings"] as? JSONObject ?? [:]; self.agents = data["agents"] as? JSONObject ?? [:]
                if let id = self.selectedID { self.select(id) }
            }
        }
    }
    func select(_ id: String?) {
        selectionRequest += 1; let requestID = selectionRequest
        if selectedID != id || id == nil { room = nil }
        selectedID = id
        let version = roomVersion
        guard let id = id else { return }
        request("api/rooms/\(id)") { result in
            guard self.selectionRequest == requestID else { return }
            switch result {
            case .success(let r):
                if self.roomVersion == version { self.room = r }
            case .failure(let e): if self.room == nil { self.error = e.localizedDescription }
            }
        }
    }
    func receive(_ ev: JSONObject) {
        switch ev["type"] as? String {
        case "agents": agents = ev["agents"] as? JSONObject ?? [:]; notice = ""
        case "room":
            guard let r = ev["room"] as? JSONObject, let id = r["id"] as? String else { return }
            let summary: JSONObject = ["id": id, "title": r["title"] ?? "", "status": r["status"] ?? "idle", "created": r["created"] ?? 0]
            if let index = rooms.firstIndex(where: { $0["id"] as? String == id }) { rooms[index] = summary } else { rooms.insert(summary, at: 0) }
            if selectedID == id { roomVersion += 1; room = r }
        case "deleted":
            guard let id = ev["id"] as? String else { return }
            rooms.removeAll { $0["id"] as? String == id }
            if selectedID == id { select(nil) }
        case "live":
            guard ev["roomId"] as? String == selectedID else { return }
            guard var r = room else { return }
            if ev["op"] as? String == "start" { r["live"] = ev["live"]; room = r; return }
            if ev["op"] as? String == "subagents", var live = r["live"] as? JSONObject {
                live["subagents"] = ev["subagents"] ?? [:]; r["live"] = live; room = r; return
            }
            guard var live = r["live"] as? JSONObject, let i = ev["i"] as? Int, i >= 0 else { return }
            var steps = live["steps"] as? [JSONObject] ?? []
            switch ev["op"] as? String {
            case "step": if let step = ev["step"] as? JSONObject, i <= steps.count { if i == steps.count { steps.append(step) } else { steps[i] = step } }
            case "set": if i < steps.count, let patch = ev["patch"] as? JSONObject { steps[i].merge(patch) { _, new in new } }
            case "append":
                if i < steps.count, let field = ev["field"] as? String, let text = ev["text"] as? String {
                    let combined = (steps[i][field] as? String ?? "") + text
                    steps[i][field] = combined.count > 12000 ? "…" + combined.suffix(12000) : combined
                }
            default: break
            }
            live["steps"] = steps; r["live"] = live; room = r
        default: break
        }
    }
    func sceneState() -> JSONObject {
        guard let r = room else { return ["agentIDs": agentIDs] }
        let members = Array(Set((r["members"] as? [String] ?? agentIDs) + Array((r["sessions"] as? JSONObject ?? [:]).keys))).sorted()
        var output: JSONObject = ["title": r["title"] as? String ?? "ห้องทำงาน", "roomID": r["id"] as? String ?? "", "agentIDs": members, "status": r["status"] ?? ""]
        let live = r["live"] as? JSONObject ?? [:], running = r["running"] as? JSONObject ?? [:]
        output["subagents"] = live["subagents"] as? JSONObject ?? [:]
        output["briefing"] = r["briefing"]
        output["status"] = r["status"]
        let waiting = r["waiting"] as? JSONObject ?? [:], messages = r["messages"] as? [JSONObject] ?? [], steps = live["steps"] as? [JSONObject] ?? []
        if let handoff = messages.reversed().first(where: { m in
            let from = m["from"] as? String ?? ""
            let to = (m["meta"] as? JSONObject)?["to"] as? String ?? ""
            return members.contains(from) && members.contains(to) && from != to
        }) { output["handoff"] = handoff }
        // Workflow rooms: tasks are the source of concurrent activity; the briefer stands in for the user during meeting/planning.
        let workflow = r["workflow"] as? JSONObject
        let tasks = workflow?["tasks"] as? [JSONObject] ?? []
        let pending = (r["questions"] as? [JSONObject] ?? []).filter { $0["status"] as? String == "pending" }
        if let phase = workflow?["phase"] as? String {
            let meeting = ["meeting", "planning"].contains(phase)
            output["meeting"] = meeting
            if meeting {
                let summary = plainText((r["briefing"] as? JSONObject)?["summary"] as? String ?? "")
                output["briefer"] = ["message": !pending.isEmpty ? "ทีมมีคำถามรอคุณตอบ" : (summary.isEmpty ? "บรีฟงานตามที่คุณสั่ง" : "บรีฟงาน: " + summary)] as JSONObject
            }
        }
        for agent in members {
            let task = tasks.first(where: { $0["owner"] as? String == agent && $0["status"] as? String == "running" })
            let taskWaiting = tasks.contains(where: { $0["owner"] as? String == agent && $0["status"] as? String == "waiting" })
            let liveAgent = (live["agent"] as? String ?? running["agent"] as? String) == agent
            let asking = pending.contains(where: { $0["from"] as? String == agent })
            let working = (task != nil || liveAgent) && !asking
            let ownSteps = (task?["live"] as? JSONObject)?["steps"] as? [JSONObject] ?? (liveAgent ? steps : [])
            let step = working ? (ownSteps.reversed().first(where: { $0["status"] as? String == "run" }) ?? ownSteps.last) : nil
            let assignment = task?["assignment"] as? String ?? ((r["assignments"] as? JSONObject)?[agent] as? JSONObject)?["assignment"] as? String ?? ""
            let activity = Self.activity(step: step, assignment: assignment, coordinator: liveAgent && running["role"] as? String == "coordinator")
            let info = agents[agent] as? JSONObject ?? [:]
            let availability = (info["installed"] as? Bool == false) ? "ไม่ได้ติดตั้ง" : ((info["restingUntil"] as? Double ?? 0) > Date().timeIntervalSince1970 * 1000 ? "พักชั่วคราว" : "พร้อม")
            let roomWaiting = r["status"] as? String == "waiting" && waiting["from"] as? String == agent
            let waitingOnMe = roomWaiting || asking || taskWaiting
            let state = working ? activity : (waitingOnMe ? "รอคุณ" : availability)
            let waitingText = asking || taskWaiting ? "รอคำตอบจากคุณ" : ["approve":"รออนุมัติแผน", "verify":"รอตรวจงานให้ครบ", "retry":"รอทำงานต่อ", "limit":"พักตามขีดจำกัดการใช้งาน"][waiting["kind"] as? String ?? ""] ?? "รอคำตอบจากคุณ"
            output[agent] = ["working": working, "speaking": working || waitingOnMe, "state": state, "message": working ? activity : (waitingOnMe ? waitingText : "")] as JSONObject
        }
        return output
    }
    static let phases: [(id: String, label: String)] = [("meeting", "ประชุม"), ("planning", "วางแผน"), ("working", "ทำงาน"), ("review", "รีวิว"), ("testing", "ทดสอบ"), ("delivered", "ส่งมอบ")]
    static let taskStatus = ["pending": "รอเริ่ม", "running": "กำลังทำ", "waiting": "รอคำตอบ", "review": "รอรีวิว", "done": "เสร็จ", "failed": "ขัดข้อง"]
    static func activity(step: JSONObject?, assignment: String, coordinator: Bool = false) -> String {
        if coordinator { return "กำลังบรีฟงานและเลือกผู้รับผิดชอบ" }
        let kind = step?["kind"] as? String ?? "", name = step?["name"] as? String ?? ""
        let title = step?["title"] as? String ?? ""
        switch kind {
        case "edit": return "กำลังแก้ไฟล์ " + (title as NSString).lastPathComponent
        case "cmd":
            let description = plainText(step?["sub"] as? String ?? "")
            if !description.isEmpty { return "กำลังรันคำสั่ง: " + description }
            if title.contains("tests/") || title.contains("--test") { return "กำลังรันทดสอบ" }
            if title.contains("swiftc ") || title.contains("build.sh") { return "กำลังตรวจ build" }
            return "กำลังรันคำสั่ง"
        case "error": return "กำลังจัดการข้อผิดพลาด"
        case "plan": return "กำลังจัดแผนงาน"
        case "think": return "กำลังวิเคราะห์งาน"
        default:
            if name == "Read" { return "กำลังอ่านไฟล์ " + (title as NSString).lastPathComponent }
            if ["Grep", "Glob"].contains(name) { return "กำลังค้นหาโค้ดที่เกี่ยวข้อง" }
            if ["Agent", "Task"].contains(name) { return "กำลังมอบหมายงานให้ผู้ช่วย" }
            if name == "Skill" { return "กำลังอ่านแนวทางการทำงาน" }
            let task = plainText(assignment)
            if !task.isEmpty { return "กำลังทำงาน: " + task }
            return kind == "text" ? "กำลังสรุปผลการทำงาน" : "กำลังทำงานตามโจทย์"
        }
    }
}

// One-line preview of agent Markdown: drop routing tags, headings, bullets, emphasis and code ticks.
func plainText(_ text: String) -> String {
    var t = text.replacingOccurrences(of: "(?s)\\[\\[NEXT\\s+.*?\\]\\]\\s*$", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s+", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "• ", options: .regularExpression)
    t = t.replacingOccurrences(of: "\\*\\*|__|`", with: "", options: .regularExpression)
    return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
