import Cocoa
import SceneKit

// One limb chain: yaw (around y) -> pitch (around x) -> elbow (around x).
struct Arm { let yaw: SCNNode; let pitch: SCNNode; let elbow: SCNNode }
struct Rig { let body: SCNNode; let left: Arm; let right: Arm; let legL: SCNNode; let legR: SCNNode; let chair: SCNNode; let chairHome: SCNVector3 }

// Desk and body sizes shared by the build and the poses, in scene units.
enum Office {
    static let deskTop: Float = 0.865
    static let seatedY: Float = 0.67, standingY: Float = 0.91
    static let bodyZ: Float = 0.20          // hips, relative to the desk row
    static let shoulder = (y: Float(0.47), upper: Float(0.29), fore: Float(0.29))
    static let keyboardZ: Float = -0.30
}

// The room is a native SceneKit view; the existing chat remains the source of truth.
final class OfficeScene: NSView {
    private let sceneView = SCNView()
    private let scene = SCNScene()
    private let camera = SCNNode()
    private var characters: [String: Rig] = [:]
    private var homes: [String: SCNVector3] = [:]
    private var meeting = false
    private var selectedRoom = ""
    private var lastHandoff = ""
    private var latestPayload: [String: Any] = [:]
    private var active: [String: Bool] = [:]
    private var yaw: Float = 0.68
    private let roomNode = SCNNode()
    private var bubbleText: [String: String] = [:]
    private var bubbleShown: [String: String] = [:]
    private var activityRotationPaused = false
    private var meetingActivity: [String: String] = [:]
    private var targetZ: Float = 0
    private var distance: Float = 10.5
    private var baseFloorLength: CGFloat = 7.8
    private var manualCamera = false
    private var lastCameraTransform: SCNMatrix4?
    private var visitorKeys: [String] = []
    private var visitorPhases: [String: String] = [:]
    private var visitorLabels: [String: String] = [:]
    private var briefingID = ""
    // Primary agents standing at the meeting table for the workflow meeting/planning phase.
    private var atTable: Set<String> = []
    private var primaryAgents: [String] = []
    private var doorway = SCNVector3(3.55, Office.standingY, 3.2)
    private func accent(_ agent: String) -> UInt32 { agentAccent(agent.split(separator: ":").first.map(String.init) ?? agent) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        buildScene()
        buildInterface()
        buildRoom()
        resetCamera()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func color(_ hex: UInt32) -> NSColor {
        NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private func material(_ hex: UInt32, emission: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = color(hex); m.roughness.contents = 0.8
        if emission > 0 { m.emission.contents = color(hex).withAlphaComponent(emission) }
        return m
    }
    @discardableResult private func box(_ parent: SCNNode, _ size: (CGFloat, CGFloat, CGFloat), _ position: (Float, Float, Float), _ hex: UInt32, radius: CGFloat = 0.04) -> SCNNode {
        let shape = SCNBox(width: size.0, height: size.1, length: size.2, chamferRadius: radius)
        shape.materials = [material(hex)]; let n = SCNNode(geometry: shape)
        n.position = SCNVector3(position.0, position.1, position.2); parent.addChildNode(n); return n
    }
    @discardableResult private func sphere(_ parent: SCNNode, _ radius: CGFloat, _ position: (Float, Float, Float), _ hex: UInt32) -> SCNNode {
        let shape = SCNSphere(radius: radius); shape.segmentCount = 32; shape.materials = [material(hex)]
        let n = SCNNode(geometry: shape); n.position = SCNVector3(position.0, position.1, position.2); parent.addChildNode(n); return n
    }
    @discardableResult private func cylinder(_ parent: SCNNode, _ radius: CGFloat, _ height: CGFloat, _ position: (Float, Float, Float), _ hex: UInt32) -> SCNNode {
        let shape = SCNCylinder(radius: radius, height: height); shape.materials = [material(hex)]
        let n = SCNNode(geometry: shape); n.position = SCNVector3(position.0, position.1, position.2); parent.addChildNode(n); return n
    }
    @discardableResult private func capsule(_ parent: SCNNode, _ radius: CGFloat, _ height: CGFloat, _ position: (Float, Float, Float), _ hex: UInt32) -> SCNNode {
        let shape = SCNCapsule(capRadius: radius, height: height); shape.materials = [material(hex)]
        let n = SCNNode(geometry: shape); n.position = SCNVector3(position.0, position.1, position.2); parent.addChildNode(n); return n
    }
    private func buildScene() {
        scene.background.contents = color(0xEEF1F1)
        sceneView.scene = scene; sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = true; sceneView.autoenablesDefaultLighting = false
        sceneView.backgroundColor = color(0xEEF1F1)
        sceneView.rendersContinuously = false
        sceneView.setAccessibilityLabel("ออฟฟิศสามมิติ ลากเพื่อหมุน ใช้ปุ่มหมุนหรือรีเซ็ตมุมมองได้")
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.72, alpha: 1); scene.rootNode.addChildNode(ambient)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.light?.intensity = 850
        light.position = SCNVector3(-3, 8, 7); scene.rootNode.addChildNode(light)
        camera.camera = SCNCamera(); camera.camera?.fieldOfView = 37; scene.rootNode.addChildNode(camera)
        resetCamera()
        scene.rootNode.addChildNode(roomNode)
    }
    private func buildRoom() {
        meeting = false; meetingActivity.removeAll(); homes.removeAll(); visitorLabels.removeAll(); atTable.removeAll()
        for model in characters.values { model.body.removeAllActions() }
        roomNode.childNodes.forEach { $0.removeFromParentNode() }; characters.removeAll(); active.removeAll(); bubbleText.removeAll(); bubbleShown.removeAll()
        let columns = min(3, max(2, primaryAgents.count)), rows = max(1, Int(ceil(Double(primaryAgents.count) / Double(columns))))
        let width: CGFloat = max(8.4, CGFloat(columns) * 3.1 + 1.3), length: CGFloat = max(7.8, CGFloat(rows) * 2.5 + 5.2)
        baseFloorLength = length; manualCamera = false
        targetZ = 0; distance = 11.2
        let room = roomNode
        box(room, (width, 0.25, length), (0, -0.16, 0), 0xC7CECD, radius: 0.13).name = "office-floor"
        box(room, (width - 0.25, 0.12, length - 0.25), (0, 0, 0), 0xD9DFDC, radius: 0.09).name = "office-surface"
        for z in stride(from: -Double(length/2) + 0.3, through: Double(length/2) - 0.3, by: 0.65) {
            box(room, (width - 0.4, 0.005, 0.008), (0, 0.064, Float(z)), 0xD3DBD8, radius: 0)
        }
        box(room, (width - 0.3, 0.45, 0.14), (0, 0.28, -Float(length/2)+0.15), 0xB6C3C1)
        box(room, (0.14, 0.45, length - 0.4), (-Float(width/2)+0.2, 0.28, 0), 0xC1CBC7).name = "office-side-wall"
        plant(room, x: -Float(width/2)+0.7, z: -Float(length/2)+0.7); plant(room, x: Float(width/2)-0.7, z: -Float(length/2)+0.7)
        for (index, agent) in primaryAgents.enumerated() {
            let row = SCNNode(); row.position.z = -(CGFloat(index / columns) - CGFloat(rows-1)/2) * 2.5; room.addChildNode(row)
            let x: Float = primaryAgents.count == 1 ? 0 : (Float(index % columns) - Float(columns - 1)/2) * 3.3
            desk(row, x: x, accent: accent(agent), agent: agent)
        }
        targetZ = 0; distance = max(11.2, Float(max(width,length))*1.65)
        box(room, (width - 2.7, 0.012, 1.9), (0, 0.069, 2.0), 0xD5DFDA, radius: 0.12)
        let table = SCNNode(); table.name = "meeting-table"; table.position.z = max(2.0,CGFloat(rows-1)*1.25+2.0); room.addChildNode(table)
        cylinder(table, 0.65, 0.08, (0, 0.74, 0), 0xD0BDA6)
        cylinder(table, 0.11, 0.64, (0, 0.39, 0), 0x758782)
        doorway = SCNVector3(Float(width/2) - 0.65, Office.standingY, Float(table.position.z) + 1.2)
        box(room, (0.75, 0.015, 0.50), (Float(doorway.x), 0.075, Float(doorway.z)), 0xa9b7a4, radius: 0.04)
    }

    // Plan against furniture footprints expanded by the person's walking clearance.
    // Returning nil keeps the person in place instead of walking through an obstacle.
    static func walkingRoute(from: SCNVector3, to: SCNVector3, obstacles: [CGRect], bounds: CGRect, clearance: CGFloat = 0.38) -> [SCNVector3]? {
        let blocked = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let area = bounds.insetBy(dx: clearance, dy: clearance)
        let start = CGPoint(x: CGFloat(from.x), y: CGFloat(from.z)), end = CGPoint(x: CGFloat(to.x), y: CGFloat(to.z))
        func valid(_ p: CGPoint) -> Bool { area.contains(p) && !blocked.contains { $0.insetBy(dx: 0.0001, dy: 0.0001).contains(p) } }
        guard valid(start), valid(end) else { return nil }
        func clear(_ a: CGPoint, _ b: CGPoint) -> Bool {
            !blocked.contains { segment(a, b, intersects: $0.insetBy(dx: 0.0001, dy: 0.0001)) }
        }
        var points = [start, end]
        for rect in blocked {
            for p in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] where valid(p) { points.append(p) }
        }
        var distances = Array(repeating: CGFloat.infinity, count: points.count), previous = Array(repeating: -1, count: points.count), visited = Set<Int>()
        distances[0] = 0
        while let current = points.indices.filter({ !visited.contains($0) && distances[$0].isFinite }).min(by: { distances[$0] < distances[$1] }) {
            if current == 1 { break }
            visited.insert(current)
            for next in points.indices where !visited.contains(next) && clear(points[current], points[next]) {
                let distance = distances[current] + hypot(points[next].x - points[current].x, points[next].y - points[current].y)
                if distance < distances[next] { distances[next] = distance; previous[next] = current }
            }
        }
        guard distances[1].isFinite else { return nil }
        var path: [SCNVector3] = [], index = 1
        while index != 0 { path.append(SCNVector3(points[index].x, CGFloat(Office.standingY), points[index].y)); index = previous[index] }
        return path.reversed()
    }
    static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        var low: CGFloat = 0, high: CGFloat = 1
        for (origin, delta, minValue, maxValue) in [(a.x, b.x-a.x, rect.minX, rect.maxX), (a.y, b.y-a.y, rect.minY, rect.maxY)] {
            if abs(delta) < 0.000001 { if origin < minValue || origin > maxValue { return false } }
            else {
                let t1 = (minValue-origin)/delta, t2 = (maxValue-origin)/delta
                low = max(low, min(t1,t2)); high = min(high, max(t1,t2))
                if low > high { return false }
            }
        }
        return high >= 0 && low <= 1
    }
    func furnitureFootprints() -> [CGRect] {
        var obstacles: [CGRect] = []
        roomNode.enumerateChildNodes { node, _ in
            guard node.name?.hasPrefix("desk:") == true else { return }
            let box = node.boundingBox, low = node.convertPosition(box.min, to: self.roomNode), high = node.convertPosition(box.max, to: self.roomNode)
            obstacles.append(CGRect(x: CGFloat(low.x), y: CGFloat(low.z), width: CGFloat(high.x-low.x), height: CGFloat(high.z-low.z)))
        }
        if let table = roomNode.childNode(withName: "meeting-table", recursively: false) { obstacles.append(CGRect(x: CGFloat(table.position.x)-0.65, y: CGFloat(table.position.z)-0.65, width: 1.3, height: 1.3)) }
        return obstacles
    }
    private func walkAction(body: SCNNode, from: SCNVector3, to: SCNVector3, speed: Double) -> (action: SCNAction, duration: TimeInterval)? {
        guard let floor = roomNode.childNode(withName: "office-floor", recursively: false), let shape = floor.geometry as? SCNBox else { return nil }
        let bounds = CGRect(x: -shape.width/2+0.2, y: CGFloat(floor.position.z)-shape.length/2, width: shape.width-0.2, height: shape.length)
        guard let parent = body.parent, let route = Self.walkingRoute(from: from, to: to, obstacles: furnitureFootprints(), bounds: bounds) else { return nil }
        var actions: [SCNAction] = [], previous = from, duration: TimeInterval = 0
        for point in route {
            let time = Double(hypot(point.x-previous.x, point.z-previous.z))/speed
            let angle = atan2(point.x-previous.x, point.z-previous.z)
            actions += [.rotateTo(x: 0, y: angle, z: 0, duration: 0.12, usesShortestUnitArc: true), .move(to: parent.convertPosition(point, from: roomNode), duration: time)]
            duration += time + 0.12; previous = point
        }
        return (.sequence(actions), duration)
    }
    private func plant(_ parent: SCNNode, x: Float, z: Float) {
        cylinder(parent, 0.23, 0.35, (x, 0.24, z), 0xc37e60)
        cylinder(parent, 0.04, 0.55, (x, 0.62, z), 0x7a9262)
        for (dx, dy, dz) in [(-0.16,0.87,0.0), (0.15,0.94,0.0), (0.0,1.08,0.0), (0.0,0.9,0.14)] {
            let leaf = sphere(parent, 0.24, (x + Float(dx), Float(dy), z + Float(dz)), 0x719b77); leaf.scale = SCNVector3(0.75, 1.2, 0.75)
        }
    }
    private func desk(_ room: SCNNode, x: Float, accent: UInt32, agent: String) {
        let top = Office.deskTop
        box(room, (2.25, 0.13, 1.0), (x, top - 0.065, -0.65), 0xC1AE95, radius: 0.05).name = "desk:" + agent
        for dx: Float in [-0.93, 0.93] { for z: Float in [-0.97, -0.33] { box(room, (0.10, CGFloat(top - 0.11), 0.10), (x + dx, (top - 0.11) / 2 + 0.04, z), 0x846857, radius: 0.02) } }
        // Monitor screen faces the person (+z).
        box(room, (0.84, 0.56, 0.08), (x, top + 0.31, -0.92), 0x48575c, radius: 0.05)
        box(room, (0.74, 0.45, 0.015), (x, top + 0.315, -0.873), 0x9dc6c2, radius: 0.02)
        box(room, (0.09, 0.12, 0.06), (x, top + 0.06, -0.96), 0x657270, radius: 0.02)
        box(room, (0.30, 0.02, 0.18), (x, top + 0.01, -0.94), 0x657270, radius: 0.01)
        let keyboard = box(room, (0.62, 0.03, 0.20), (x, top + 0.015, Office.keyboardZ), 0xf6eee1, radius: 0.012); keyboard.name = "keyboard:" + agent
        box(room, (0.07, 0.025, 0.11), (x + 0.48, top + 0.0125, Office.keyboardZ), 0xf6eee1, radius: 0.012)
        cylinder(room, 0.075, 0.15, (x - 0.82, top + 0.075, -0.6), 0xf5e5d2)
        // The chair rolls back when the person stands up.
        let z = Office.bodyZ
        let chair = SCNNode(); chair.name = "chair:" + agent; chair.position = SCNVector3(x, 0, z); room.addChildNode(chair)
        box(chair, (0.66, 0.16, 0.38), (0, 0.49, 0.02), 0x6d7776, radius: 0.08)
        box(chair, (0.70, 0.66, 0.11), (0, 0.92, 0.27), 0x718582, radius: 0.10)
        box(chair, (0.08, 0.32, 0.05), (0, 0.55, 0.25), 0x4b5659, radius: 0.02)
        cylinder(chair, 0.055, 0.30, (0, 0.26, 0.02), 0x4b5659)
        box(chair, (0.56, 0.05, 0.08), (0, 0.12, 0.02), 0x4b5659, radius: 0.02)
        box(chair, (0.08, 0.05, 0.50), (0, 0.12, 0.02), 0x4b5659, radius: 0.02)

        makeCharacter(room, x: x, z: z, accent: accent, agent: agent, chair: chair)
    }
    private func makeCharacter(_ room: SCNNode, x: Float, z: Float, accent: UInt32, agent: String, chair: SCNNode) {
        let body = SCNNode(); body.name = "agent:" + agent; body.position = SCNVector3(x, Office.seatedY, z); room.addChildNode(body)
        body.eulerAngles.y = .pi
        homes[agent] = body.position
        let female = agent.utf8.reduce(0) { $0 + Int($1) } % 2 == 0
        let variation = agent.utf8.reduce(0) { ($0 + Int($1)) % 3 }
        let skin: UInt32 = [0xf0c7a6, 0xe5b592, 0xc99372][variation]
        let hairColor: UInt32 = female ? 0x49322d : 0x303941
        let pants: UInt32 = female ? 0x3d3f52 : 0x414c59

        let jacket = box(body, (female ? 0.42 : 0.49, 0.60, 0.30), (0, 0.27, 0), accent, radius: 0.10)
        jacket.name = female ? "woman-jacket" : "man-jacket"
        box(body, (0.15, 0.42, 0.02), (0, 0.30, 0.152), 0xf6efe4, radius: 0.01)
        if !female { box(body, (0.045, 0.27, 0.02), (0, 0.33, 0.165), 0x39434a, radius: 0.01) }
        cylinder(body, 0.07, 0.12, (0, 0.61, 0), skin)

        // Head art is drawn at the old 0.86 head height and scaled down as one piece.
        let head = SCNNode(); head.name = "head"; head.position = SCNVector3(0, 0.885, 0); head.scale = SCNVector3(0.92, 0.92, 0.92); body.addChildNode(head)
        let skull = sphere(head, 0.255, (0, 0, 0), skin); skull.scale = SCNVector3(0.91, 1.12, 0.88)
        let hair = sphere(head, 0.266, (0, 0.12, -0.045), hairColor); hair.scale = SCNVector3(0.94, 0.68, 0.90)
        for dx: Float in [-0.235, 0.235] { sphere(head, 0.045, (dx, -0.01, 0), skin) }
        if female {
            box(head, (0.42, 0.40, 0.16), (0, -0.07, -0.16), hairColor, radius: 0.075)
            for dx: Float in [-0.215, 0.215] {
                let lock = sphere(head, 0.12, (dx, -0.04, -0.095), hairColor); lock.scale = SCNVector3(0.56, 1.7, 0.82)
                sphere(head, 0.022, (dx * 1.1, -0.065, 0.015), 0xe2c17c)
                let lash = box(head, (0.032, 0.009, 0.012), (dx * 0.53, 0.032, 0.214), 0x2c2326, radius: 0.004)
                lash.eulerAngles.z = dx < 0 ? 0.35 : -0.35
            }
        } else {
            let fringe = box(head, (0.34, 0.10, 0.18), (-0.035, 0.165, 0.12), hairColor, radius: 0.045); fringe.eulerAngles.z = -0.16
        }
        for dx: Float in [-0.085, 0.085] {
            let eye = sphere(head, 0.030, (dx, 0.01, 0.214), 0xfff7ea); eye.scale = SCNVector3(1.12, 0.58, 0.35)
            sphere(head, 0.015, (dx, 0.008, 0.227), 0x363339)
            box(head, (0.061, 0.012, 0.018), (dx, 0.065, 0.208), hairColor, radius: 0.005)
        }
        let nose = sphere(head, 0.024, (0, -0.036, 0.23), skin); nose.scale = SCNVector3(0.75, 1.25, 0.8)
        let smile = SCNTorus(ringRadius: female ? 0.033 : 0.035, pipeRadius: female ? 0.008 : 0.005); smile.materials = [material(female ? 0xc0605f : 0x895f54)]
        let mouth = SCNNode(geometry: smile); mouth.position = SCNVector3(0, -0.082, 0.207); mouth.eulerAngles.x = .pi / 2; mouth.scale = SCNVector3(1, 0.25, 0.45); head.addChildNode(mouth)

        func arm(_ x: Float, name: String) -> Arm {
            let yaw = SCNNode(); yaw.name = name; yaw.position = SCNVector3(x, Office.shoulder.y, 0); body.addChildNode(yaw)
            let pitch = SCNNode(); yaw.addChildNode(pitch)
            sphere(pitch, 0.072, (0, 0, 0), accent)
            capsule(pitch, 0.068, CGFloat(Office.shoulder.upper + 0.10), (0, -Office.shoulder.upper / 2, 0), accent)
            let elbow = SCNNode(); elbow.name = "elbow"; elbow.position = SCNVector3(0, -Office.shoulder.upper, 0); pitch.addChildNode(elbow)
            capsule(elbow, 0.060, CGFloat(Office.shoulder.fore), (0, -Office.shoulder.fore / 2 + 0.02, 0), accent)
            cylinder(elbow, 0.040, 0.05, (0, -Office.shoulder.fore + 0.055, 0), 0xf6efe4)
            let hand = sphere(elbow, 0.052, (0, -Office.shoulder.fore, 0), skin); hand.name = "hand"; hand.scale = SCNVector3(0.85, 1.1, 1)
            return Arm(yaw: yaw, pitch: pitch, elbow: elbow)
        }
        let half: Float = female ? 0.21 : 0.245
        let left = arm(-(half + 0.075), name: "arm-left"), right = arm(half + 0.075, name: "arm-right")
        func leg(_ x: Float, name: String) -> SCNNode {
            let hip = SCNNode(); hip.name = name; hip.position = SCNVector3(x, -0.02, 0); body.addChildNode(hip)
            box(hip, (0.17, 0.30, 0.17), (0, -0.14, 0), pants, radius: 0.06)
            let knee = SCNNode(); knee.name = "knee"; knee.position = SCNVector3(0, -0.28, 0); hip.addChildNode(knee)
            box(knee, (0.145, 0.46, 0.15), (0, -0.23, 0), pants, radius: 0.05)
            let foot = box(knee, (0.15, 0.10, 0.25), (0, -0.50, 0.04), female ? 0x5a2f2c : 0x29323b, radius: 0.04); foot.name = "foot"
            return hip
        }
        let legL = leg(-0.11, name: "hip-left"), legR = leg(0.11, name: "hip-right")
        characters[agent] = Rig(body: body, left: left, right: right, legL: legL, legR: legR, chair: chair, chairHome: chair.position)
        deskPose(agent, typing: false)
    }

    // Two-bone reach: point the arm at a body-space target and bend the elbow downward.
    private func reach(_ arm: Arm, to target: SIMD3<Float>) {
        let p = arm.yaw.position
        let d = target - SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        let a = Office.shoulder.upper, b = Office.shoulder.fore
        let length = min(simd_length(d), a + b - 0.001)
        let flat = (d.x * d.x + d.z * d.z).squareRoot()
        let toward = atan2(-flat, -d.y)
        let shoulder = acos(max(-1, min(1, (a * a + length * length - b * b) / (2 * a * length))))
        let elbow = acos(max(-1, min(1, (a * a + b * b - length * length) / (2 * a * b))))
        arm.yaw.eulerAngles = SCNVector3(0, CGFloat(atan2(d.x, d.z)), 0)
        arm.pitch.eulerAngles = SCNVector3(CGFloat(toward + shoulder), 0, 0)
        arm.elbow.eulerAngles = SCNVector3(CGFloat(-(Float.pi - elbow)), 0, 0)
    }
    private func stopLimbs(_ rig: Rig) {
        for n in [rig.left.yaw, rig.left.pitch, rig.left.elbow, rig.right.yaw, rig.right.pitch, rig.right.elbow, rig.legL, rig.legR] { n.removeAllActions() }
    }
    private func seatedPose(_ key: String, seated: Bool) {
        guard let model = characters[key] else { return }
        for hip in [model.legL, model.legR] {
            hip.removeAllActions(); hip.eulerAngles = SCNVector3(seated ? -1.45 : 0, 0, 0)
            hip.childNode(withName: "knee", recursively: false)?.eulerAngles = SCNVector3(seated ? 1.45 : 0, 0, 0)
        }
    }
    // Seated at the desk: hands on the keyboard while working, on the lap otherwise.
    private func deskPose(_ key: String, typing: Bool) {
        guard let model = characters[key] else { return }
        stopLimbs(model); seatedPose(key, seated: true)
        let reachZ = Office.bodyZ - Office.keyboardZ - 0.03      // hand just in front of the keyboard centre
        let handY = Office.deskTop + 0.085 - Office.seatedY
        for (arm, side) in [(model.left, Float(-1)), (model.right, Float(1))] {
            reach(arm, to: typing ? SIMD3(side * 0.15, handY, reachZ) : SIMD3(side * 0.13, 0.11, 0.22))
        }
        guard typing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (i, arm) in [model.left, model.right].enumerated() {
            let base = arm.elbow.eulerAngles.x
            let tap = SCNAction.sequence([.rotateTo(x: base - 0.13, y: 0, z: 0, duration: 0.16), .rotateTo(x: base + 0.03, y: 0, z: 0, duration: 0.16)])
            arm.elbow.runAction(.sequence([.wait(duration: Double(i) * 0.16), .repeatForever(tap)]), forKey: "working")
        }
    }
    private func walkPose(_ key: String, moving: Bool) {
        guard let model = characters[key] else { return }
        stopLimbs(model); seatedPose(key, seated: false)
        for arm in [model.left, model.right] {
            arm.yaw.eulerAngles = SCNVector3Zero; arm.pitch.eulerAngles = SCNVector3(0.06, 0, 0); arm.elbow.eulerAngles = SCNVector3(-0.22, 0, 0)
        }
        guard moving else { return }
        func swing(_ s: CGFloat) -> SCNAction { .repeatForever(.sequence([.rotateTo(x: 0.38 * s, y: 0, z: 0, duration: 0.24), .rotateTo(x: -0.38 * s, y: 0, z: 0, duration: 0.24)])) }
        model.legL.runAction(swing(1)); model.right.pitch.runAction(swing(0.8))
        model.legR.runAction(swing(-1)); model.left.pitch.runAction(swing(-0.8))
    }
    // Standing and talking: one hand gestures, the head nods a little.
    private func talkPose(_ key: String) {
        guard let model = characters[key] else { return }
        walkPose(key, moving: false)
        model.right.pitch.eulerAngles = SCNVector3(-0.35, 0, 0)
        model.right.elbow.runAction(.repeatForever(.sequence([.rotateTo(x: -0.9, y: 0, z: 0, duration: 0.45), .rotateTo(x: -1.35, y: 0, z: 0, duration: 0.45)])))
        model.body.childNode(withName: "head", recursively: false)?.runAction(.sequence([.rotateBy(x: 0.12, y: 0, z: 0, duration: 0.3), .rotateBy(x: -0.12, y: 0, z: 0, duration: 0.3)]))
    }
    private func resetCamera() {
        camera.position = SCNVector3(sin(yaw) * distance, distance * 0.77, targetZ + cos(yaw) * distance)
        camera.look(at: SCNVector3(0, 0.35, targetZ))
        sceneView.pointOfView = camera
        sceneView.defaultCameraController.target = SCNVector3(0, 0.35, targetZ)
        lastCameraTransform = camera.transform
    }
    @objc func rotateLeft() { manualCamera = true; yaw -= 0.4; resetCamera() }
    @objc func rotateRight() { manualCamera = true; yaw += 0.4; resetCamera() }
    @objc func resetView() { manualCamera = false; yaw = 0.68; resetCamera() }

    // Keep each activity page readable, including Thai words and unbroken identifiers.
    static func speechPages(_ source: String) -> [String] {
        let text = plainText(source)
        guard !text.isEmpty else { return [] }
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        func fits(_ value: String) -> Bool { value.count <= 72 && bubbleLayout(value, font: font, maxWidth: 360, maxLines: 2).text == value }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .localized]) { sentence, _, _, _ in if let sentence = sentence { sentences.append(sentence) } }
        if sentences.isEmpty { sentences = [text] }
        var pages: [String] = []
        for sentence in sentences {
            let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if fits(sentence) { pages.append(sentence); continue }
            var tokens: [String] = [], start = sentence.startIndex
            sentence.enumerateSubstrings(in: sentence.startIndex..<sentence.endIndex, options: [.byWords, .localized]) { _, range, _, _ in
                tokens.append(String(sentence[start..<range.upperBound])); start = range.upperBound
            }
            if start < sentence.endIndex { tokens.append(String(sentence[start...])) }
            var page = ""
            for token in tokens {
                let candidate = (page + token).trimmingCharacters(in: .whitespacesAndNewlines)
                if fits(candidate) { page += token; continue }
                if !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pages.append(page.trimmingCharacters(in: .whitespacesAndNewlines)); page = "" }
                if fits(token.trimmingCharacters(in: .whitespacesAndNewlines)) { page = token }
                else {
                    // One oversized word/identifier has no word boundary; preserve whole graphemes.
                    for character in token {
                        if !page.isEmpty && !fits(page + String(character)) { pages.append(page.trimmingCharacters(in: .whitespacesAndNewlines)); page = "" }
                        page.append(character)
                    }
                }
            }
            if !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pages.append(page.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return pages.filter { !$0.isEmpty }
    }

    static func bubbleLayout(_ text: String, font: NSFont = .systemFont(ofSize: 26, weight: .medium), maxWidth: CGFloat = 470, maxLines: Int = 3) -> (text: String, size: NSSize) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        func measure(_ s: String) -> NSSize {
            let r = (s as NSString).boundingRect(with: NSSize(width: maxWidth, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            return NSSize(width: ceil(r.width), height: ceil(r.height))
        }
        let limit = ceil(NSLayoutManager().defaultLineHeight(for: font) * CGFloat(maxLines)) + 1
        var shown = text
        if measure(text).height > limit {
            let chars = Array(text); var lo = 0, hi = chars.count
            while lo < hi { let mid = (lo + hi + 1) / 2; if measure(String(chars[..<mid]) + "…").height <= limit { lo = mid } else { hi = mid - 1 } }
            shown = String(chars[..<lo]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return (shown, measure(shown))
    }
    private func updateBubble(_ text: String, for key: String, body: SCNNode) {
        let clean = plainText(text)
        guard bubbleText[key] != clean else { return }
        bubbleText[key] = clean
        body.removeAction(forKey: "speech-pages")
        let pages = Self.speechPages(clean)
        renderBubble(pages.first ?? "", for: key, body: body)
        guard pages.count > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let actions = pages.flatMap { page -> [SCNAction] in
            [.run({ [weak self, weak body] _ in
                guard let self = self, let body = body, self.characters[key]?.body === body, self.bubbleText[key] == clean else { return }
                self.renderBubble(page, for: key, body: body)
            }, queue: .main), .wait(duration: max(3, min(7, Double(page.count)/10)))]
        }
        let rotation = SCNAction.repeatForever(.sequence(actions)); rotation.speed = activityRotationPaused ? 0 : 1
        body.runAction(rotation, forKey: "speech-pages")
    }
    func setActivityRotationPaused(_ paused: Bool) {
        activityRotationPaused = paused
        for model in characters.values { model.body.action(forKey: "speech-pages")?.speed = paused ? 0 : 1 }
    }
    func displayedActivity(for key: String) -> String { bubbleShown[key] ?? "" }
    private func renderBubble(_ text: String, for key: String, body: SCNNode) {
        guard bubbleShown[key] != text else { return }
        bubbleShown[key] = text
        body.childNode(withName: "speech", recursively: false)?.removeFromParentNode()
        let clean = plainText(text)
        guard !clean.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        let layout = Self.bubbleLayout(clean, font: font, maxWidth: 360, maxLines: 2)
        let pad: CGFloat = 20, tail: CGFloat = 16
        let size = NSSize(width: max(120, layout.size.width + pad * 2), height: layout.size.height + pad * 2 - 6 + tail)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let shape = NSBezierPath(roundedRect: NSRect(x: 2, y: tail, width: size.width - 4, height: size.height - tail - 2), xRadius: 20, yRadius: 20)
        shape.move(to: NSPoint(x: size.width / 2 - 14, y: tail + 1)); shape.line(to: NSPoint(x: size.width / 2, y: 1)); shape.line(to: NSPoint(x: size.width / 2 + 14, y: tail + 1)); shape.close()
        NSColor.white.withAlphaComponent(0.97).setFill(); shape.fill()
        NSColor(calibratedWhite: 0, alpha: 0.10).setStroke(); shape.lineWidth = 1.5; shape.stroke()
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
        (layout.text as NSString).draw(with: NSRect(x: pad, y: tail + pad - 3, width: layout.size.width + 1, height: layout.size.height), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1), .paragraphStyle: style])
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size); image.addRepresentation(rep)
        let scale: CGFloat = 0.0036
        let plane = SCNPlane(width: size.width * scale, height: size.height * scale)
        let material = SCNMaterial(); material.diffuse.contents = image; material.lightingModel = .constant; material.isDoubleSided = true; plane.materials = [material]
        let bubble = SCNNode(geometry: plane); bubble.name = "speech"; bubble.position = SCNVector3(0, 1.24 + size.height * scale / 2, 0)
        bubble.constraints = [SCNBillboardConstraint()]; body.addChildNode(bubble)
    }

    private func buildInterface() {
        addSubview(sceneView); sceneView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sceneView.leadingAnchor.constraint(equalTo: leadingAnchor), sceneView.trailingAnchor.constraint(equalTo: trailingAnchor), sceneView.topAnchor.constraint(equalTo: topAnchor), sceneView.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    func update(_ payload: [String: Any]) {
        latestPayload = payload
        if let ids = payload["agentIDs"] as? [String], ids != primaryAgents {
            cancelMeeting(); primaryAgents = ids; visitorKeys = []; visitorPhases = [:]; briefingID = ""; buildRoom(); resetCamera()
        }
        let subagents = payload["subagents"] as? [String: [String: Any]] ?? [:]
        let roomID = payload["roomID"] as? String ?? ""
        let handoff = payload["handoff"] as? [String: Any] ?? [:]
        let eventID = handoff["id"] as? String ?? ""
        if selectedRoom != roomID {
            cancelMeeting()
            for key in Array(characters.keys) where key.contains(":") || key == "briefer" { removeVisitor(key) }
            visitorKeys = []; briefingID = ""
            resizeVisitorArea()
            selectedRoom = roomID; lastHandoff = eventID
        }
        syncVisitors(subagents)
        syncBriefer(payload["briefer"] as? [String: Any])
        let gathering = payload["meeting"] as? Bool == true
        if !meeting && gathering != !atTable.isEmpty { gather(gathering) }

        for key in primaryAgents {
            let data = payload[key] as? [String: Any] ?? [:]
            // Bubbles only while the agent is talking now (working or waiting on the user); finished rooms stay quiet.
            if let model = characters[key] {
                let activity = meetingActivity[key] ?? (data["speaking"] as? Bool == true ? data["message"] as? String ?? "กำลังทำงาน" : (atTable.contains(key) ? "ร่วมประชุมบรีฟงาน" : ""))
                updateBubble(activity, for: key, body: model.body)
            }
            let working = key.contains(":") || (data["working"] as? Bool ?? false)
            guard !meeting, !atTable.contains(key), active[key] != working, characters[key] != nil else { continue }
            active[key] = working
            deskPose(key, typing: working)
        }
        if !eventID.isEmpty && eventID != lastHandoff && !meeting {
            lastHandoff = eventID
            // Everyone is already at the table during a workflow meeting; no extra walk-over.
            if atTable.isEmpty { meet(handoff) }
        }
    }
    // The briefer stands in for the user behind the meeting table; present only while the payload asks for it.
    private func syncBriefer(_ data: [String: Any]?) {
        let key = "briefer"
        guard let data = data else { if characters[key] != nil { leaveVisitor(key) }; return }
        let text = data["message"] as? String ?? ""
        visitorLabels[key] = text
        if characters[key] == nil || visitorPhases[key] == "leaving" {
            guard let table = roomNode.childNode(withName: "meeting-table", recursively: false) else { return }
            enterVisitor(key, accent: 0x4E5A63, at: SCNVector3(table.position.x, CGFloat(Office.standingY), table.position.z - 1.15), text: text, facing: table.position)
        } else if visitorPhases[key] == "discussing", let body = characters[key]?.body { updateBubble(text, for: key, body: body) }
    }
    // Two columns either side of the table, three deep, widening outward for larger teams.
    static func meetingPositions(count: Int, tableZ: CGFloat) -> [SCNVector3] {
        (0..<count).map { index in
            let side: CGFloat = index % 2 == 0 ? -1 : 1, slot = index / 2
            return SCNVector3(side * (1.15 + CGFloat(slot / 3) * 0.85), CGFloat(Office.standingY), tableZ + [0, -0.9, 0.9][slot % 3])
        }
    }
    // Walk every primary agent to the table (or back to the desk). An agent without a clear route stays put.
    private func gather(_ on: Bool) {
        guard let table = roomNode.childNode(withName: "meeting-table", recursively: false) else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let spots = Self.meetingPositions(count: primaryAgents.count, tableZ: table.position.z)
        for (index, key) in primaryAgents.enumerated() where on != atTable.contains(key) {
            guard let model = characters[key], let home = homes[key], let parent = model.body.parent else { continue }
            let stand = SCNVector3(home.x, CGFloat(Office.standingY), home.z + 0.08), standWorld = parent.convertPosition(stand, to: roomNode)
            model.body.removeAction(forKey: "gather"); model.chair.removeAllActions()
            if on {
                let spot = spots[index]
                guard let path = walkAction(body: model.body, from: standWorld, to: spot, speed: 1.6) else { continue }
                atTable.insert(key); active.removeValue(forKey: key)
                meetingActivity[key] = "กำลังเดินไปประชุม"; updateBubble(meetingActivity[key]!, for: key, body: model.body)
                model.chair.runAction(.move(to: SCNVector3(model.chairHome.x, model.chairHome.y, model.chairHome.z + 0.5), duration: 0.35))
                model.body.runAction(.sequence([
                    .run({ _ in self.walkPose(key, moving: false) }, queue: .main),
                    .move(to: stand, duration: reduced ? 0 : 0.4),
                    .run({ _ in self.walkPose(key, moving: !reduced) }, queue: .main),
                    reduced ? .move(to: parent.convertPosition(spot, from: roomNode), duration: 0) : path.action,
                    .rotateTo(x: 0, y: atan2(table.position.x - spot.x, table.position.z - spot.z), z: 0, duration: reduced ? 0 : 0.25, usesShortestUnitArc: true),
                    .run({ _ in self.meetingActivity.removeValue(forKey: key); self.talkPose(key); self.update(self.latestPayload) }, queue: .main)
                ]), forKey: "gather")
            } else {
                atTable.remove(key)
                let current = model.body.presentation.position; model.body.position = current
                // Clearing `active` lets update()'s agent loop re-seat the person with the right typing pose.
                let finish = { self.meetingActivity.removeValue(forKey: key); self.active.removeValue(forKey: key); model.chair.position = model.chairHome }
                guard !reduced, let path = walkAction(body: model.body, from: parent.convertPosition(current, to: roomNode), to: standWorld, speed: 1.6) else {
                    model.body.position = home; model.body.eulerAngles = SCNVector3(0, Float.pi, 0); finish(); continue
                }
                meetingActivity[key] = "กำลังกลับไปทำงาน"; updateBubble(meetingActivity[key]!, for: key, body: model.body)
                model.chair.runAction(.sequence([.wait(duration: path.duration + 0.3), .move(to: model.chairHome, duration: 0.4)]))
                model.body.runAction(.sequence([
                    .run({ _ in self.walkPose(key, moving: true) }, queue: .main),
                    path.action,
                    .run({ _ in self.walkPose(key, moving: false) }, queue: .main),
                    .rotateTo(x: 0, y: .pi, z: 0, duration: 0.25, usesShortestUnitArc: true),
                    .run({ _ in self.seatedPose(key, seated: true) }, queue: .main),
                    .move(to: home, duration: 0.4),
                    .run({ _ in finish(); self.update(self.latestPayload) }, queue: .main)
                ]), forKey: "gather")
            }
        }
    }

    private func removeVisitor(_ key: String) {
        characters[key]?.body.removeAllActions(); characters[key]?.body.removeFromParentNode()
        visitorPhases.removeValue(forKey: key)
        visitorLabels.removeValue(forKey: key)
        characters.removeValue(forKey: key); homes.removeValue(forKey: key)
        bubbleText.removeValue(forKey: key); active.removeValue(forKey: key)
        bubbleShown.removeValue(forKey: key)
        resizeVisitorArea()
    }
    private func enterVisitor(_ key: String, accent: UInt32, at position: SCNVector3, text: String, facing: SCNVector3 = SCNVector3(0, 0, 1)) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let isNew = characters[key] == nil
        if isNew {
            makeCharacter(roomNode, x: Float(doorway.x), z: Float(doorway.z), accent: accent, agent: key, chair: SCNNode())
            characters[key]?.body.position.y = CGFloat(Office.standingY)
            if key == "briefer" { characters[key]?.body.name = "briefer" }
        }
        guard let body = characters[key]?.body else { return }
        var current = isNew ? body.position : body.presentation.position
        current.y = CGFloat(Office.standingY)
        body.removeAction(forKey: "visit"); body.position = current; body.opacity = 1
        visitorPhases[key] = "arriving"
        guard let path = walkAction(body: body, from: body.convertPosition(SCNVector3Zero, to: roomNode), to: position, speed: 1.6) else { removeVisitor(key); return }
        walkPose(key, moving: !reduced)
        updateBubble("กำลังเข้าร่วมงาน", for: key, body: body)
        body.runAction(.sequence([reduced ? .move(to: position, duration: 0) : path.action, .run({ _ in
            guard self.characters[key]?.body === body else { return }
            self.visitorPhases[key] = "discussing"
            // Set all three angles: a walk turn can leave x/z at π (the same as a half-turn about y).
            body.eulerAngles = SCNVector3(0, atan2(facing.x - position.x, facing.z - position.z), 0)
            self.talkPose(key); self.updateBubble(self.visitorLabels[key] ?? text, for: key, body: body)
        }, queue: .main)]), forKey: "visit")
    }
    private func leaveVisitor(_ key: String) {
        guard let body = characters[key]?.body, visitorPhases[key] != "leaving" else { return }
        let current = body.presentation.position
        body.removeAction(forKey: "visit"); body.position = current; body.removeAction(forKey: "brief-end")
        visitorPhases[key] = "leaving"; updateBubble("", for: key, body: body)
        walkPose(key, moving: true)
        guard let path = walkAction(body: body, from: body.convertPosition(SCNVector3Zero, to: roomNode), to: doorway, speed: 1.6) else { removeVisitor(key); return }
        body.runAction(.sequence([NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .move(to: doorway, duration: 0) : path.action, .fadeOut(duration: 0.15), .run({ _ in
            if self.characters[key]?.body === body && self.visitorPhases[key] == "leaving" { self.removeVisitor(key) }
        }, queue: .main)]), forKey: "visit")
    }
    private func syncVisitors(_ members: [String: [String: Any]]) {
        let desired = members.keys.sorted().compactMap { id -> String? in
            guard let team = members[id]?["agent"] as? String, primaryAgents.contains(team) else { return nil }
            return team + ":" + id
        }
        for key in visitorKeys where !desired.contains(key) { leaveVisitor(key) }
        let changed = desired != visitorKeys
        visitorKeys = desired
        for key in desired {
            let id = String(key.split(separator: ":", maxSplits: 1)[1])
            visitorLabels[key] = "กำลังช่วย: " + (members[id]?["label"] as? String ?? "ทำงานที่ได้รับมอบหมาย")
            if visitorPhases[key] == "discussing", let body = characters[key]?.body { updateBubble(visitorLabels[key]!, for: key, body: body) }
        }
        guard changed else { return }
        resizeVisitorArea()
        guard !desired.isEmpty else { return }
        let positions = Self.visitorPositions(count: desired.count, tableZ: roomNode.childNode(withName: "meeting-table", recursively: false)?.position.z ?? 2)
        for (index, key) in desired.enumerated() {
            let label = visitorLabels[key] ?? "กำลังช่วยทำงาน"
            characters[key]?.body.opacity = 1
            enterVisitor(key, accent: accent(key), at: positions[index], text: label)
        }
    }
    static func visitorPositions(count: Int, tableZ: CGFloat) -> [SCNVector3] {
        let columns = max(1, min(5, count))
        return (0..<count).map { index in SCNVector3((CGFloat(index % columns)-CGFloat(columns-1)/2)*1.5, CGFloat(Office.standingY), tableZ+1.55+CGFloat(index/columns)*1.25) }
    }
    private func resizeVisitorArea() {
        guard let floor = roomNode.childNode(withName:"office-floor",recursively:false), let shape = floor.geometry as? SCNBox else { return }
        let tableZ = roomNode.childNode(withName:"meeting-table",recursively:false)?.position.z ?? 2
        let planned = Self.visitorPositions(count:visitorKeys.count,tableZ:tableZ).map(\.z)
        // Keep space for helpers still walking out, then restore the original footprint.
        let present = characters.filter { $0.key.contains(":") }.map { $0.value.body.presentation.position.z }
        let requiredFront = max(baseFloorLength/2, (planned + present).max().map { $0 + 0.7 } ?? baseFloorLength/2)
        let delta = baseFloorLength/2 + requiredFront - shape.length
        guard abs(delta) > 0.001 else { return }
        let follow = !manualCamera && sceneView.pointOfView === camera && (lastCameraTransform.map { SCNMatrix4EqualToMatrix4(camera.transform,$0) } ?? true)
        for name in ["office-floor","office-surface","office-side-wall"] {
            if let node = roomNode.childNode(withName:name,recursively:false), let geometry = node.geometry as? SCNBox { geometry.length += delta; node.position.z += delta/2 }
        }
        targetZ = Float(floor.position.z); distance = max(11.2,Float(max(shape.width,shape.length))*1.65)
        if follow { resetCamera() } else { manualCamera = true }
    }
    private func cancelMeeting() {
        meeting = false; meetingActivity.removeAll(); atTable.removeAll()
        for (key, model) in characters where !key.contains(":") && key != "briefer" {
            model.body.removeAction(forKey: "meeting"); model.body.removeAction(forKey: "meeting-end"); model.body.removeAction(forKey: "gather"); model.chair.removeAllActions()
            if let home = homes[key] { model.body.position = home }
            model.chair.position = model.chairHome
            model.body.eulerAngles = SCNVector3(0, Float.pi, 0)
            deskPose(key, typing: false)
        }
        active.removeAll()
    }
    // Stand up, walk to the centre aisle, talk, walk back, sit down.
    private func meet(_ event: [String: Any]) {
        guard let from = event["from"] as? String,
              let to = (event["meta"] as? [String: Any])?["to"] as? String,
              from != to, characters[from] != nil, characters[to] != nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard let table = roomNode.childNode(withName: "meeting-table", recursively: false) else { return }
        var plans: [(key: String, rig: Rig, home: SCNVector3, stand: SCNVector3, side: CGFloat, outward: SCNAction, back: SCNAction, sitAt: TimeInterval)] = []
        var finishAt: TimeInterval = 0
        let fromWorld = characters[from]!.body.convertPosition(SCNVector3Zero, to: roomNode)
        let toWorld = characters[to]!.body.convertPosition(SCNVector3Zero, to: roomNode)
        for (index, key) in [from, to].enumerated() {
            guard let model = characters[key], let home = homes[key] else { continue }
            let fromLeft = abs(fromWorld.x-toWorld.x) < 0.01 ? true : fromWorld.x < toWorld.x
            let side: CGFloat = (index == 0 ? fromLeft : !fromLeft) ? -1 : 1
            let stand = SCNVector3(home.x, CGFloat(Office.standingY), home.z + 0.08)
            let standWorld = model.body.parent!.convertPosition(stand, to: roomNode)
            let spot = SCNVector3(side * 1.15, CGFloat(Office.standingY), table.position.z)
            guard let outward = walkAction(body: model.body, from: standWorld, to: spot, speed: 1.6), let back = walkAction(body: model.body, from: spot, to: standWorld, speed: 1.6) else { return }
            let sitAt = 0.4 + outward.duration + 0.25 + 3.0 + back.duration + 0.25
            plans.append((key, model, home, stand, side, outward.action, back.action, sitAt))
            finishAt = max(finishAt, sitAt+0.5)
        }
        meeting = true
        for plan in plans {
            let key = plan.key, model = plan.rig
            meetingActivity[key] = "กำลังเดินไปส่งต่องาน"
            updateBubble(meetingActivity[key]!, for: key, body: model.body)
            let face = { (y: CGFloat) in SCNAction.rotateTo(x: 0, y: y, z: 0, duration: 0.25, usesShortestUnitArc: true) }
            let pushed = SCNVector3(model.chairHome.x, model.chairHome.y, model.chairHome.z + 0.5)
            model.chair.runAction(.sequence([.move(to: pushed, duration: 0.35), .wait(duration: plan.sitAt - 0.35), .move(to: model.chairHome, duration: 0.4)]))
            let walk = SCNAction.sequence([
                .run({ _ in self.walkPose(key, moving: false) }, queue: .main),
                .move(to: plan.stand, duration: 0.4),
                .run({ _ in self.walkPose(key, moving: true) }, queue: .main),
                plan.outward,
                face(-plan.side * .pi / 2),
                .run({ _ in self.talkPose(key); self.meetingActivity[key] = "กำลังหารือและส่งต่องาน"; self.updateBubble(self.meetingActivity[key]!, for: key, body: model.body) }, queue: .main),
                .wait(duration: 3.0),
                .run({ _ in self.walkPose(key, moving: true); self.meetingActivity[key] = "กำลังกลับไปทำงานต่อ"; self.updateBubble(self.meetingActivity[key]!, for: key, body: model.body) }, queue: .main),
                plan.back,
                .run({ _ in self.walkPose(key, moving: false) }, queue: .main),
                face(.pi),
                .run({ _ in self.seatedPose(key, seated: true) }, queue: .main),
                .move(to: plan.home, duration: 0.4),
                .run({ _ in self.deskPose(key, typing: false) }, queue: .main)
            ])
            model.body.runAction(walk, forKey: "meeting")
        }
        characters[from]?.body.runAction(.sequence([.wait(duration: finishAt), .run { _ in
            DispatchQueue.main.async { self.meeting = false; self.meetingActivity.removeAll(); self.active.removeAll(); self.update(self.latestPayload) }
        }]), forKey: "meeting-end")
    }
}
