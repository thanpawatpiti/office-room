import Cocoa
import SceneKit
import Metal

final class RoomResponse: URLProtocol {
    static var respond: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "room-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async { Self.respond = {
            let data = Data("{\"id\":\"room\",\"live\":{\"steps\":[{\"kind\":\"text\",\"body\":\"hello\"}]}}".utf8)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url:self.request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!, cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self, didLoad:data)
            self.client?.urlProtocolDidFinishLoading(self)
        } }
    }
    override func stopLoading() {}
}

@main struct NativeTests {
    static func main() {
        URLProtocol.registerClass(RoomResponse.self)
        let loading = OfficeStore(base:URL(string:"http://room-test.invalid/")!)
        loading.select("room")
        loading.receive(["type":"live", "roomId":"room", "op":"append", "i":0, "field":"body", "text":"hello"])
        func waitFor(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !condition() && Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
            precondition(condition(), "request did not complete")
        }
        waitFor { RoomResponse.respond != nil }
        RoomResponse.respond?(); RoomResponse.respond = nil
        waitFor { loading.room != nil }
        precondition(((loading.room?["live"] as? JSONObject)?["steps"] as? [JSONObject])?.first?["body"] as? String == "hello", "snapshot text must not be appended twice")
        loading.room?["running"] = NSNull()
        precondition(!loading.isRunning)
        loading.room?["running"] = ["agent":"claude"]
        precondition(loading.isRunning)
        loading.select("room")
        precondition(loading.room != nil, "refresh must preserve room")
        waitFor { RoomResponse.respond != nil }
        loading.receive(["type":"room", "room":["id":"room", "title":"newer"]])
        RoomResponse.respond?(); RoomResponse.respond = nil
        RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        precondition(loading.room?["title"] as? String == "newer", "older response must not overwrite room event")
        let asking = OfficeStore(base: URL(string:"http://127.0.0.1:1/")!)
        let ask: JSONObject = ["id":"q1", "from":"codex", "text":"ใช้ A หรือ B?"]
        asking.room = ["id":"r1", "status":"waiting", "waiting":["kind":"ask", "from":"codex"], "messages":[ask]]
        precondition(asking.pendingQuestion()?["key"] as? String == "r1:q1:ask", "agent question must pop up")
        asking.room?["waiting"] = ["kind":"approve", "from":"codex"]
        precondition(asking.pendingQuestion()?["kind"] as? String == "approve", "approval must pop up")
        asking.room?["messages"] = [ask, ["id":"s0", "from":"system", "text":"codex ขอให้ claude แก้ไฟล์ แต่ยังไม่ได้รับอนุมัติ"]]
        precondition(asking.pendingQuestion()?["key"] as? String == "r1:q1:approve", "approval after the server's note must pop up")
        asking.room?["messages"] = [ask, ["id":"u1", "from":"user", "text":"แก้แผน"], ["id":"s2", "from":"system", "text":"x"]]
        precondition(asking.pendingQuestion() == nil, "answered approval must not pop up again")
        asking.room?["waiting"] = ["kind":"ask", "from":"codex"]
        asking.room?["messages"] = [ask, ["id":"u1", "from":"user", "text":"A"]]
        precondition(asking.pendingQuestion() == nil, "answered question must not pop up again")
        asking.room?["messages"] = [ask, ["id":"s1", "from":"system", "text":"หยุดแล้ว"]]
        precondition(asking.pendingQuestion() == nil, "a stop is not a question")
        asking.room?["messages"] = [ask]; asking.room?["waiting"] = ["kind":"retry", "from":"codex"]
        precondition(asking.pendingQuestion() == nil, "retry/limit stay as buttons")
        asking.room?["waiting"] = ["kind":"ask", "from":"codex"]; asking.room?["status"] = "running"
        precondition(asking.pendingQuestion() == nil, "running room has no question")
        // Structured prompts: shown while running (native Codex request), before legacy prose, never over an approval.
        let prompt: JSONObject = ["id":"p1", "from":"codex", "status":"pending", "source":"room", "questions":[
            ["id":"scope", "header":"ขอบเขต", "question":"ทำส่วนไหน?", "multiSelect":false, "options":[["id":"o1","label":"แอป","description":"เฉพาะ macOS"], ["id":"o2","label":"ทั้งหมด","description":""]]],
            ["id":"parts", "header":"", "question":"ส่วนประกอบ?", "multiSelect":true, "options":[["id":"o1","label":"A","description":""], ["id":"o2","label":"B","description":""]]],
            ["id":"note", "header":"", "question":"อธิบายเพิ่ม", "multiSelect":false, "options":[]]]]
        asking.room?["questions"] = [prompt]
        precondition(asking.pendingQuestion()?["kind"] as? String == "questions" && asking.pendingQuestion()?["key"] as? String == "r1:p1:questions", "pending structured prompt must pop up even while running")
        precondition(asking.pendingQuestion()?["text"] as? String == "ใช้ A หรือ B?", "room prompt carries the asker's message as context")
        asking.room?["status"] = "waiting"; asking.room?["waiting"] = ["kind":"approve", "from":"codex"]
        precondition(asking.pendingQuestion()?["kind"] as? String == "approve", "approval keeps its own plan popup")
        asking.room?["waiting"] = ["kind":"ask", "from":"codex"]
        precondition(asking.pendingQuestion()?["kind"] as? String == "questions", "structured prompt replaces the prose ask popup")
        var expired = prompt; expired["status"] = "expired"; asking.room?["questions"] = [expired]
        precondition(asking.pendingQuestion()?["kind"] as? String == "ask", "expired prompt cannot be answered; legacy prose remains")
        let items = prompt["questions"] as! [JSONObject]
        var draft = AnswerDraft()
        precondition(OfficeStore.answerBody(prompt, draft) == nil, "nothing is preselected or sent for the user")
        draft.choose("o2", in: "scope", multi: false); draft.choose("o1", in: "scope", multi: false)
        precondition(draft.selected["scope"] == ["o1"], "single choice keeps one option")
        draft.type("อย่างอื่น", in: "scope", multi: false)
        precondition(draft.selected["scope"] == [] && draft.isAnswered(items[0]), "typed answer replaces a single choice")
        draft.choose("o2", in: "scope", multi: false)
        precondition(draft.text["scope"] == "" && draft.selected["scope"] == ["o2"], "choosing an option replaces typed text")
        draft.choose("o2", in: "parts", multi: true); draft.choose("o1", in: "parts", multi: true); draft.type("C", in: "parts", multi: true)
        precondition(OfficeStore.answerBody(prompt, draft) == nil, "every question needs an answer")
        draft.type("   ", in: "note", multi: false)
        precondition(!draft.isAnswered(items[2]), "blank text is not an answer")
        draft.type("รายละเอียด", in: "note", multi: false)
        let body = OfficeStore.answerBody(prompt, draft)!
        precondition((body["parts"] as! JSONObject)["selected"] as! [String] == ["o1", "o2"] && (body["parts"] as! JSONObject)["text"] as? String == "C", "multi-select keeps option order plus custom text")
        precondition((body["scope"] as! JSONObject)["selected"] as! [String] == ["o2"] && (body["note"] as! JSONObject)["text"] as? String == "รายละเอียด")
        precondition(OfficeStore.answerSummary(items[1], draft) == "A, B, C")
        print("Structured question priority, single/multi/custom answers and no preselection passed")
        // Workflow: concurrent tasks drive per-member activity; a waiting task does not stop the other worker.
        let team = OfficeStore(base: URL(string:"http://127.0.0.1:1/")!)
        team.agents = ["claude":["installed":true], "codex":["installed":true]]
        team.room = ["id":"w", "status":"running", "members":["claude","codex"], "messages":[], "briefing":["summary":"ปรับหน้าคำถาม"],
                     "workflow":["phase":"meeting", "participants":["claude","codex"], "tasks":[], "documents":[]]]
        var stateW = team.sceneState()
        precondition(stateW["meeting"] as? Bool == true && (stateW["briefer"] as? JSONObject)?["message"] as? String == "บรีฟงาน: ปรับหน้าคำถาม", "meeting phase brings the user's briefer")
        team.room?["questions"] = [prompt]
        precondition((team.sceneState()["briefer"] as? JSONObject)?["message"] as? String == "ทีมมีคำถามรอคุณตอบ")
        precondition((team.sceneState()["codex"] as? JSONObject)?["message"] as? String == "รอคำตอบจากคุณ", "asking member shows it waits on the user")
        team.room?["questions"] = []
        team.room?["workflow"] = ["phase":"working", "tasks":[
            ["id":"ui", "owner":"claude", "assignment":"ทำหน้าคำถาม", "files":["/p/app/NativeUI.swift"], "dependsOn":[], "status":"running", "revision":0, "live":["steps":[["kind":"tool","name":"Read","title":"/p/app/NativeUI.swift","status":"run"]]]],
            ["id":"api", "owner":"codex", "assignment":"ทำ backend", "files":["/p/server.js"], "dependsOn":[], "status":"running", "revision":0]]]
        stateW = team.sceneState()
        precondition(stateW["meeting"] as? Bool == false && stateW["briefer"] == nil, "briefer leaves once work starts")
        precondition((stateW["claude"] as? JSONObject)?["working"] as? Bool == true && (stateW["claude"] as? JSONObject)?["message"] as? String == "กำลังอ่านไฟล์ NativeUI.swift")
        precondition((stateW["codex"] as? JSONObject)?["working"] as? Bool == true && (stateW["codex"] as? JSONObject)?["message"] as? String == "กำลังทำงาน: ทำ backend", "both workers are active in parallel")
        var tasksW = (team.room?["workflow"] as! JSONObject)["tasks"] as! [JSONObject]; tasksW[1]["status"] = "waiting"
        team.room?["workflow"] = ["phase":"working", "tasks":tasksW]
        stateW = team.sceneState()
        precondition((stateW["codex"] as? JSONObject)?["working"] as? Bool == false && (stateW["codex"] as? JSONObject)?["message"] as? String == "รอคำตอบจากคุณ" && (stateW["claude"] as? JSONObject)?["working"] as? Bool == true, "waiting task does not stop the independent one")
        let legacy = OfficeStore(base: URL(string:"http://127.0.0.1:1/")!)
        legacy.room = ["id":"old", "status":"running", "members":["claude"], "messages":[], "briefing":["summary":"x"]]
        precondition(legacy.sceneState()["meeting"] == nil && legacy.sceneState()["briefer"] == nil, "legacy rooms keep the old scene payload")
        print("Workflow phase briefer, concurrent task activity and waiting isolation passed")
        let parser = EventStreamParser()
        let bytes = Data("data: {\"type\":\"room\",\"title\":\"ทดสอบ\"}\n\ndata: {\"type\":\"agents\"}\n\n".utf8)
        var events: [JSONObject] = []
        for byte in bytes { events += parser.append(Data([byte])) }
        precondition(events.count == 2 && events[0]["title"] as? String == "ทดสอบ")
        let store = OfficeStore(base: URL(string:"http://127.0.0.1:1/")!)
        store.selectedID = "room"; store.agents = ["claude":["installed":true],"codex":["installed":true]]
        store.room = ["id":"room", "title":"งาน", "running":["agent":"claude"], "live":["agent":"claude", "steps":[]], "messages":[]]
        store.receive(["type":"live", "roomId":"room", "op":"subagents", "subagents":["1":["id":"1","agent":"claude"], "2":["id":"2","agent":"codex"]]])
        precondition((store.sceneState()["subagents"] as? JSONObject)?.count == 2)
        store.receive(["type":"live", "roomId":"room", "op":"step", "i":0, "step":["kind":"text","body":"สวัสดี"]])
        precondition((store.sceneState()["claude"] as? JSONObject)?["message"] as? String == "กำลังสรุปผลการทำงาน", "activity must describe the work, not repeat answer text")
        precondition((store.sceneState()["claude"] as? JSONObject)?["speaking"] as? Bool == true, "working agent shows a bubble")
        precondition((store.sceneState()["codex"] as? JSONObject)?["speaking"] as? Bool == false, "idle agent in a room stays quiet")
        guard MTLCreateSystemDefaultDevice() != nil else { print("Native delivery, question state, SSE and activity state passed; SKIP animated scene checks: no Metal device"); return }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        let office = OfficeScene(frame:NSRect(x:0,y:0,width:1000,height:700)); window.contentView = office; window.orderFrontRegardless()
        office.update(store.sceneState())
        let scene = office.subviews.compactMap { $0 as? SCNView }.first!
        func advance(_ duration: TimeInterval) {
            RunLoop.current.run(until:Date().addingTimeInterval(duration))
        }
        advance(0.5)
        func names() -> [String] { var a:[String] = []; scene.scene?.rootNode.enumerateChildNodes { n,_ in if let name = n.name, name.hasPrefix("agent:") { a.append(name) } }; return a }
        precondition(names().count == 4)
        office.rotateLeft()
        let preserved = scene.pointOfView!.transform
        let floor = scene.scene!.rootNode.childNode(withName:"office-floor", recursively:true)!
        let floorBounds = floor.boundingBox
        let visitor = scene.scene!.rootNode.childNode(withName:"agent:claude:1", recursively:true)!
        func deskCount() -> Int { var count = 0; scene.scene!.rootNode.enumerateChildNodes { n, _ in if n.name?.hasPrefix("desk:") == true { count += 1 } }; return count }
        precondition(deskCount() == 2, "helpers must not create more desks")
        advance(3.2)
        precondition(abs(visitor.position.x - 3.55) > 0.2, "helper must walk into gathering area")
        precondition(abs(visitor.position.y - CGFloat(Office.standingY)) < 0.01, "helper must stand, not sit: \(visitor.position), action=\(String(describing: visitor.action(forKey: "visit")?.duration))")
        office.update(["roomID":"room"]); precondition(visitor.action(forKey:"visit") != nil, "helper must visibly walk out")
        advance(5)
        precondition(names().count == 2, "finished helpers must leave")
        precondition(deskCount() == 2 && floor.boundingBox.max.x == floorBounds.max.x, "furniture and floor must remain unchanged")
        precondition(SCNMatrix4EqualToMatrix4(scene.pointOfView!.transform, preserved), "membership must preserve camera")
        office.resetView()
        let camera = scene.pointOfView!, start = camera.position; office.rotateLeft(); precondition(camera.position.x != start.x); office.resetView(); precondition(abs(camera.position.x - start.x) < 0.001)
        let first: JSONObject = ["roomID":"history-room", "handoff":["id":"old", "from":"claude", "meta":["to":"codex"]]]
        office.update(first)
        let person = scene.scene!.rootNode.childNode(withName:"agent:claude", recursively:true)!
        precondition(person.action(forKey:"meeting") == nil, "old history must not replay")
        precondition(person.childNode(withName:"woman-jacket", recursively:true) != nil)
        let colleague = scene.scene!.rootNode.childNode(withName:"agent:codex", recursively:true)!
        precondition(colleague.childNode(withName:"man-jacket", recursively:true) != nil)
        let hip = person.childNode(withName:"hip-left", recursively:true)!
        let knee = hip.childNode(withName:"knee", recursively:false)!
        precondition(abs(hip.eulerAngles.x + 1.45) < 0.01 && abs(knee.eulerAngles.x - 1.45) < 0.01)
        let kneePosition = knee.convertPosition(SCNVector3Zero, to:person.parent)
        precondition(kneePosition.z < 0.52, "shin must be in front of seat, not through it")
        let home = person.position
        office.update(["roomID":"history-room", "handoff":["id":"new", "from":"claude", "meta":["to":"codex"]]])
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(person.action(forKey:"meeting") != nil)
            advance(2.5)
            precondition(abs(person.position.x - home.x) > 0.2, "person did not walk to colleague")
            advance(5.8)
            precondition(abs(person.position.x - home.x) < 0.05 && abs(person.position.z - home.z) < 0.05, "person did not return to desk")
        }
        precondition(abs(hip.eulerAngles.x + 1.45) < 0.01, "must sit after returning")
        // Physical fit at the desk, checked on world positions rather than joint angles.
        let row = person.parent!
        let chair = row.childNode(withName:"chair:claude", recursively:false)!
        precondition(abs(chair.position.z - home.z) < 0.01, "chair must roll back under the desk after the meeting")
        office.update(["roomID":"history-room", "handoff":["id":"new", "from":"claude", "meta":["to":"codex"]], "claude":["working":true]])
        let keyboard = row.childNode(withName:"keyboard:claude", recursively:false)!.position
        for side in ["arm-left", "arm-right"] {
            let arm = person.childNode(withName:side, recursively:false)!
            let hand = arm.childNode(withName:"hand", recursively:true)!.convertPosition(SCNVector3Zero, to:row)
            let elbow = arm.childNode(withName:"elbow", recursively:true)!.convertPosition(SCNVector3Zero, to:row)
            precondition(abs(hand.x - keyboard.x) < 0.31 && abs(hand.z - keyboard.z) < 0.10, "\(side) hand must be over the keyboard, got \(hand)")
            precondition(hand.y - keyboard.y > 0.03 && hand.y - keyboard.y < 0.10, "\(side) hand must rest just above the keys, got \(hand.y)")
            precondition(elbow.y > keyboard.y + 0.02, "\(side) forearm must stay above the desk top")
        }
        for name in ["hip-left", "hip-right"] {
            let leg = person.childNode(withName:name, recursively:false)!
            let foot = leg.childNode(withName:"foot", recursively:true)!.convertPosition(SCNVector3Zero, to:row)
            let knee = leg.childNode(withName:"knee", recursively:true)!.convertPosition(SCNVector3Zero, to:row)
            precondition(abs((foot.y - 0.05) - 0.06) < 0.02, "feet must touch the floor, got \(foot.y - 0.05)")
            precondition(knee.z + 0.075 < chair.position.z + 0.02 - 0.19, "shin must clear the seat front")
        }
        let long = OfficeScene.bubbleLayout(String(repeating:"รีวิวแอป Office Room บน macOS ผลโดยรวม ", count:8))
        let short = OfficeScene.bubbleLayout("รับทราบ")
        precondition(long.text.hasSuffix("…") && long.size.height > short.size.height * 2 && long.size.height < short.size.height * 3.6, "long speech must wrap to at most 3 lines")
        precondition(short.size.width < 200, "short speech bubble must fit its text")
        precondition(plainText("## หัวข้อ\n- **ตัวหนา** `code` [[NEXT to=done]]") == "หัวข้อ • ตัวหนา code")
        print("Hands on keyboard, feet on floor, chair clearance, speech wrapping passed")
        print("Seated rig, male/female models, walking and native state passed")
        office.update(["roomID":"brief-room", "status":"running", "briefing":["status":"ready", "summary":"ออกแบบหน้าจอ", "lead":"codex", "firstStep":"ตรวจโค้ด"]])
        precondition(scene.scene!.rootNode.childNode(withName:"coordinator", recursively:true) == nil, "the coordinator role must not fabricate another agent")
        precondition(deskCount() == 2)
        advance(12)
        precondition(scene.scene!.rootNode.childNode(withName:"coordinator", recursively:true) == nil, "coordinator must leave after briefing")
        for count in [0, 1, 3, 6, 12] {
            let ids = (0..<count).map { "worker-\($0)" }
            office.update(["roomID":"n-\(count)","agentIDs":ids])
            precondition(names().count == count && deskCount() == count, "each actual primary identity needs one person and one desk")
            for id in ids {
                let person = scene.scene!.rootNode.childNode(withName:"agent:" + id, recursively:true)!
                let world = person.convertPosition(SCNVector3Zero, to:nil)
                let floor = scene.scene!.rootNode.childNode(withName:"office-floor", recursively:true)!.boundingBox
                precondition(world.x >= floor.min.x && world.x <= floor.max.x && world.z >= floor.min.z && world.z <= floor.max.z, "all people must fit on the floor")
            }
        }
        print("Dynamic 0/1/3/6/12 primary agents, desks and floor bounds passed")
        print("Native SSE, scene state, agent add/remove and camera controls passed")
    }
}
