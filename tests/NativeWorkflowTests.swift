import Cocoa
import SceneKit
import Metal

@main struct NativeWorkflowTests {
    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let text = "กำลังตรวจระบบส่งข้อความและสิทธิ์แก้ไขไฟล์ให้ตรงกับแผนที่อนุมัติ จากนั้นจะตรวจเส้นทางเดินของตัวละครให้หลบโต๊ะทุกตัว. Checking the latest test results before handing the work to the reviewer."
        let pages = OfficeScene.speechPages(text)
        precondition(pages.count > 2)
        func compact(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }
        precondition(compact(pages.joined()) == compact(text), "pagination must preserve the full activity text")
        for page in pages {
            precondition(page.count <= 72 && !page.hasSuffix("…"))
            precondition(OfficeScene.bubbleLayout(page, font: .systemFont(ofSize: 24, weight: .medium), maxWidth: 360, maxLines: 2).text == page, "each speech page must fit without truncation")
        }
        precondition(OfficeScene.speechPages("").isEmpty)
        let identifier = String(repeating: "ก้", count: 150)
        precondition(OfficeScene.speechPages(identifier).joined() == identifier, "oversized tokens must preserve Thai combining characters")
        precondition(OfficeStore.activity(step: ["kind":"tool", "name":"Read", "title":"/project/server.js"], assignment: "") == "กำลังอ่านไฟล์ server.js")
        precondition(OfficeStore.activity(step: ["kind":"cmd", "title":"node tests/workflow-integration.test.js"], assignment: "") == "กำลังรันทดสอบ")
        precondition(OfficeStore.activity(step: ["kind":"text", "body":"This answer must stay in chat"], assignment: "ตรวจการส่งข้อความ") == "กำลังทำงาน: ตรวจการส่งข้อความ")
        print("Thai/English activity pagination, whole graphemes and real tool status passed")

        let office = OfficeScene(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: office.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = office; window.orderFrontRegardless()
        let view = office.subviews.compactMap { $0 as? SCNView }.first!
        // SCNView owns the scene clock; a second renderer would compete with it.
        func tick() { RunLoop.current.run(until: Date().addingTimeInterval(1.0/30)) }
        func node(_ name: String) -> SCNNode { view.scene!.rootNode.childNode(withName: name, recursively: true)! }
        func bounds() -> CGRect {
            let floor = node("office-floor"), shape = floor.geometry as! SCNBox
            return CGRect(x: -shape.width/2+0.2, y: CGFloat(floor.position.z)-shape.length/2, width: shape.width-0.2, height: shape.length)
        }
        var routeCount = 0
        for count in [2, 3, 6, 12] {
            let ids = (0..<count).map { "worker-\($0)" }
            office.update(["roomID":"paths-\(count)", "agentIDs":ids])
            let table = node("meeting-table"), parent = table.parent!
            let obstacles = office.furnitureFootprints()
            precondition(!table.isHidden && obstacles.count == count+1)
            for id in ids {
                let body = node("agent:" + id)
                let stand = body.parent!.convertPosition(SCNVector3(body.position.x, CGFloat(Office.standingY), body.position.z+0.08), to: parent)
                for side: CGFloat in [-1, 1] {
                    let destination = SCNVector3(side*1.15, CGFloat(Office.standingY), table.position.z)
                    guard let route = OfficeScene.walkingRoute(from: stand, to: destination, obstacles: obstacles, bounds: bounds()) else { preconditionFailure("No route for \(count) agents, \(id), side \(side)") }
                    var previous = stand
                    for point in route {
                        for rect in obstacles {
                            precondition(!OfficeScene.segment(CGPoint(x: CGFloat(previous.x), y: CGFloat(previous.z)), CGPoint(x: CGFloat(point.x), y: CGFloat(point.z)), intersects: rect.insetBy(dx: -0.37, dy: -0.37)), "route crosses furniture or walking clearance")
                        }
                        previous = point
                    }
                    routeCount += 1
                }
            }
        }
        precondition(OfficeScene.walkingRoute(from: SCNVector3(0, 1, 0), to: SCNVector3(2, 1, 2), obstacles: [CGRect(x: -1, y: -1, width: 2, height: 2)], bounds: CGRect(x: -5, y: -5, width: 10, height: 10)) == nil, "blocked starts must never fall back to a straight line")
        print("\(routeCount) routes across 2/3/6/12-agent layouts clear every desk and meeting table passed")

        let fitting = OfficeScene(frame:NSRect(x:0,y:0,width:1000,height:700))
        let fittedView = fitting.subviews.compactMap { $0 as? SCNView }.first!
        let fitIDs = ["fit-a","fit-b"]
        fitting.update(["roomID":"fit", "agentIDs":fitIDs])
        let fittedFloor = fittedView.scene!.rootNode.childNode(withName:"office-floor",recursively:true)!
        let baseLength = (fittedFloor.geometry as! SCNBox).length, baseCamera = fittedView.pointOfView!.position
        let fitHelpers = Dictionary(uniqueKeysWithValues:(0..<30).map { ("h-\($0)",["agent":"fit-a"]) })
        fitting.update(["roomID":"fit","agentIDs":fitIDs,"subagents":Dictionary(uniqueKeysWithValues:fitHelpers.sorted(by:{$0.key<$1.key}).prefix(20).map { ($0.key,$0.value) })])
        precondition((fittedFloor.geometry as! SCNBox).length > baseLength && fittedFloor.position.z > 0)
        precondition(fittedView.pointOfView!.position.z != baseCamera.z, "default camera must fit the expanded area")
        fittedView.pointOfView!.position.x += 1 // Simulate a camera-controller drag.
        let manual = fittedView.pointOfView!.transform
        fitting.update(["roomID":"fit","agentIDs":fitIDs,"subagents":fitHelpers])
        precondition(SCNMatrix4EqualToMatrix4(fittedView.pointOfView!.transform,manual), "helper growth must preserve a user-adjusted camera")
        fitting.resetView()
        precondition(!SCNMatrix4EqualToMatrix4(fittedView.pointOfView!.transform,manual), "reset must fit the current room")
        fitting.update(["roomID":"fit-empty","agentIDs":fitIDs])
        precondition(abs((fittedFloor.geometry as! SCNBox).length-baseLength) < 0.001 && abs(fittedFloor.position.z) < 0.001, "removing helpers must restore the floor")
        precondition(abs(fittedView.pointOfView!.position.z-baseCamera.z) < 0.001, "default camera must restore after shrinking")
        print("Camera follows floor growth/restoration and preserves manual orbit passed")

        let canAnimate = MTLCreateSystemDefaultDevice() != nil
        if canAnimate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let table = node("meeting-table"), parent = table.parent!, bodies = [node("agent:worker-0"), node("agent:worker-11")]
            let home = bodies.map { $0.position }
            office.update(["roomID":"paths-12", "agentIDs":(0..<12).map { "worker-\($0)" }, "handoff":["id":"new-handoff", "from":"worker-0", "meta":["to":"worker-11"]]])
            precondition(bodies.allSatisfy { $0.action(forKey: "meeting") != nil })
            var samples = 0
            while bodies.contains(where: { $0.action(forKey: "meeting") != nil }) && samples < 1200 {
                tick()
                precondition(!table.isHidden && table.parent === parent, "meeting furniture must remain visible throughout a handoff")
                for body in bodies {
                    let p = body.presentation.convertPosition(SCNVector3Zero, to: parent)
                    if p.y > CGFloat(Office.standingY)-0.01 {
                        for rect in office.furnitureFootprints() { precondition(!rect.insetBy(dx: -0.32, dy: -0.32).contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.z))), "animated body crosses furniture") }
                    }
                }
                samples += 1
            }
            for (index, body) in bodies.enumerated() {
                precondition(body.action(forKey: "meeting") == nil && abs(body.position.x-home[index].x) < 0.01 && abs(body.position.z-home[index].z) < 0.01, "handoff must return to the original desk: position=\(body.position), home=\(home[index]), action duration=\(String(describing: body.action(forKey: "meeting")?.duration))")
            }
            print("\(samples) animated handoff samples keep furniture visible and people clear passed")
        }
        let originalLength = (node("office-floor").geometry as! SCNBox).length
        let helpers = Dictionary(uniqueKeysWithValues: (0..<20).map { ("helper-\($0)", ["agent":"worker-0", "label":text]) })
        office.update(["roomID":"paths-12", "agentIDs":(0..<12).map { "worker-\($0)" }, "subagents":helpers])
        precondition(!node("meeting-table").isHidden)
        let positions = OfficeScene.visitorPositions(count:20,tableZ:node("meeting-table").position.z)
        for (i, position) in positions.enumerated() {
            for other in positions.dropFirst(i+1) { precondition(hypot(position.x-other.x,position.z-other.z) > 1.0) }
            for rect in office.furnitureFootprints() { precondition(!rect.insetBy(dx:-0.38,dy:-0.38).contains(CGPoint(x:CGFloat(position.x),y:CGFloat(position.z)))) }
            precondition(OfficeScene.walkingRoute(from:SCNVector3(4.65,Office.standingY,6.95),to:position,obstacles:office.furnitureFootprints(),bounds:bounds()) != nil)
        }
        print("20 helper destinations have separate slots and furniture-safe entry routes passed")
        for count in [1, 2, 3, 6, 12] {
            let ids = (0..<count).map { "member-\($0)" }
            office.update(["roomID":"meet-\(count)", "agentIDs":ids])
            let table = node("meeting-table"), parent = table.parent!, obstacles = office.furnitureFootprints()
            let spots = OfficeScene.meetingPositions(count: count, tableZ: table.position.z)
            let briefer = SCNVector3(table.position.x, CGFloat(Office.standingY), table.position.z - 1.15)
            for (i, spot) in spots.enumerated() {
                for other in spots.dropFirst(i+1) + [briefer] { precondition(hypot(spot.x-other.x, spot.z-other.z) > 0.8, "meeting spots must not overlap (\(count) members)") }
                let body = node("agent:" + ids[i])
                let stand = body.parent!.convertPosition(SCNVector3(body.position.x, CGFloat(Office.standingY), body.position.z+0.08), to: parent)
                precondition(OfficeScene.walkingRoute(from: stand, to: spot, obstacles: obstacles, bounds: bounds()) != nil, "member \(i) of \(count) must reach the meeting table")
            }
            let door = SCNVector3(bounds().maxX - 0.65, CGFloat(Office.standingY), table.position.z + 1.2)
            precondition(OfficeScene.walkingRoute(from: door, to: briefer, obstacles: obstacles, bounds: bounds()) != nil, "briefer must reach the head of the table (\(count) members)")
        }
        print("Meeting spots for 1/2/3/6/12 members and the briefer are reachable and separate passed")
        office.update(["roomID":"paths-12", "agentIDs":(0..<12).map { "worker-\($0)" }, "subagents":helpers])
        guard canAnimate else { print("SKIP animated handoff, arrival and rotating-text checks: Metal device unavailable in this sandbox"); window.orderOut(nil); return }
        for _ in 0..<600 {
            if !(0..<20).contains(where: { node("agent:worker-0:helper-\($0)").action(forKey: "visit") != nil }) { break }
            tick()
        }
        let visitors = (0..<20).map { node("agent:worker-0:helper-\($0)") }
        for (i, body) in visitors.enumerated() {
            precondition(body.action(forKey: "visit") == nil)
            let p = body.position
            for other in visitors.dropFirst(i+1) { precondition(hypot(p.x-other.position.x, p.z-other.position.z) > 1.0, "many helpers must not be squeezed into overlapping slots") }
            for rect in office.furnitureFootprints() { precondition(!rect.insetBy(dx: -0.38, dy: -0.38).contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.z)))) }
        }
        let first = visitors[0]
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(first.action(forKey: "speech-pages") != nil)
            var seen = Set<String>()
            for _ in 0..<240 {
                seen.insert(office.displayedActivity(for: "worker-0:helper-0"))
                tick()
            }
            precondition(seen.count >= 2, "long activity must rotate through readable pages")
            office.setActivityRotationPaused(true); tick()
            let paused = office.displayedActivity(for: "worker-0:helper-0")
            for _ in 0..<240 { tick() }
            precondition(office.displayedActivity(for: "worker-0:helper-0") == paused, "users must be able to pause rotating text")
            office.setActivityRotationPaused(false)
        }
        office.update(["roomID":"paths-12", "agentIDs":(0..<12).map { "worker-\($0)" }])
        let exitDeadline = Date().addingTimeInterval(12)
        while visitors.contains(where: { $0.parent != nil }) && Date() < exitDeadline { tick() }
        precondition(visitors.allSatisfy { $0.parent == nil }, "helpers must finish walking out")
        precondition(abs((node("office-floor").geometry as! SCNBox).length-originalLength) < 0.001, "floor must shrink after the last helper exits")
        office.update(["roomID":"paths-12", "agentIDs":(0..<12).map { "worker-\($0)" }, "subagents":["transient":["agent":"worker-0","label":text]]])
        let transient = node("agent:worker-0:transient")
        office.update(["roomID":"another-room", "agentIDs":["worker-0"]])
        precondition(first.action(forKey: "speech-pages") == nil && first.parent == nil, "switching rooms must dispose speech actions")
        precondition(transient.action(forKey:"visit") == nil && transient.parent == nil, "room switching must cancel a helper still entering")
        print("20 helper slots clear furniture, pages rotate/pause, floor restores and room switching cleans up passed")
        let pair = ["meet-a", "meet-b"]
        office.update(["roomID":"meeting", "agentIDs":pair])
        let members = pair.map { node("agent:" + $0) }, homesAtDesk = members.map { $0.position }
        office.update(["roomID":"meeting", "agentIDs":pair, "meeting":true, "briefer":["message":"บรีฟงานตามที่คุณสั่ง"]])
        let briefer = node("briefer")
        precondition(view.scene!.rootNode.childNode(withName: "coordinator", recursively: true) == nil)
        let meetDeadline = Date().addingTimeInterval(12)
        while (members.contains { $0.action(forKey: "gather") != nil } || briefer.action(forKey: "visit") != nil) && Date() < meetDeadline { tick() }
        let tableNow = node("meeting-table")
        for body in members {
            let p = body.convertPosition(SCNVector3Zero, to: tableNow.parent!)
            precondition(abs(abs(p.x) - 1.15) < 0.05 && abs(p.z - tableNow.position.z) < 0.05 && abs(p.y - CGFloat(Office.standingY)) < 0.01, "members stand at the table during the meeting, got \(p)")
        }
        precondition(abs(briefer.position.z - (tableNow.position.z - 1.15)) < 0.05 && office.displayedActivity(for: "briefer") == "บรีฟงานตามที่คุณสั่ง", "briefer stands at the head of the table and speaks for the user")
        for body in members + [briefer] {
            let front = body.presentation.convertVector(SCNVector3(0, 0, 1), to: nil), from = body.presentation.convertPosition(SCNVector3Zero, to: nil), to = tableNow.convertPosition(SCNVector3Zero, to: nil)
            let dx = to.x - from.x, dz = to.z - from.z
            precondition((front.x * dx + front.z * dz) / hypot(dx, dz) > 0.95, "\(body.name ?? "") must face the meeting table")
        }
        office.update(["roomID":"meeting", "agentIDs":pair, "meeting":false, "meet-a":["working":true], "meet-b":["working":true]])
        let backDeadline = Date().addingTimeInterval(12)
        while (members.contains { $0.action(forKey: "gather") != nil } || briefer.parent != nil) && Date() < backDeadline { tick() }
        precondition(briefer.parent == nil, "briefer leaves when the meeting ends")
        for (i, body) in members.enumerated() {
            precondition(abs(body.position.x - homesAtDesk[i].x) < 0.01 && abs(body.position.z - homesAtDesk[i].z) < 0.01 && abs(body.position.y - CGFloat(Office.seatedY)) < 0.01, "members return to their own desks")
        }
        precondition(pair.allSatisfy { id in node("agent:" + id).childNode(withName: "arm-left", recursively: false)!.childNode(withName: "elbow", recursively: true)!.action(forKey: "working") != nil }, "both members type in parallel after the meeting")
        office.update(["roomID":"meeting", "agentIDs":pair, "meeting":true, "briefer":["message":"x"]])
        office.update(["roomID":"meeting-other", "agentIDs":pair])
        precondition(members.allSatisfy { $0.action(forKey: "gather") == nil } && view.scene!.rootNode.childNode(withName: "briefer", recursively: true) == nil, "switching rooms cancels the meeting and removes the briefer")
        print("Briefer enters, members meet at the table, return to desks and work in parallel passed")
        window.orderOut(nil)
    }
}
