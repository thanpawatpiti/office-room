import Cocoa
import SwiftUI
import SceneKit

@main struct NativeUITests { static func main() {
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let store = OfficeStore(base:URL(string:"http://127.0.0.1:1")!)
let agent:JSONObject = ["models":["opus","sonnet","haiku"],"model":"opus","effort":"medium","maxEffort":"high","efforts":["low","medium","high"]]
store.settings = ["agents":["claude":agent,"codex":agent],"dispatcher":["agent":"claude","model":"haiku","effort":"low"],"leadGuide":"งานวิเคราะห์ให้ Claude นำ งานเขียนโค้ดให้ Codex นำ", "maxAutoTurns":8,"cooldownMin":60,"timeoutMin":40]
// Many discovered CLIs must remain reachable while the settings footer stays pinned.
store.agents = Dictionary(uniqueKeysWithValues: (0..<8).map { ("fixture-\($0)", ["installed":true,"supported":true,"displayName":"Fixture \($0)"] as JSONObject) })
let w=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:680),styleMask:[.titled],backing:.buffered,defer:false)
let host=NSHostingView(rootView:SettingsView(store:store));w.contentView=host;w.orderFrontRegardless()
RunLoop.current.run(until:Date().addingTimeInterval(1))
func scrolls(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrolls) }
let views = scrolls(host)
precondition(!views.isEmpty, "settings is not scrollable")
let outer = views.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }!
precondition(outer.documentView!.bounds.height > outer.contentView.bounds.height)
outer.contentView.scroll(to: NSPoint(x: 0, y: outer.documentView!.bounds.height)); outer.reflectScrolledClipView(outer.contentView)
print("Settings scroll area: content \(outer.documentView!.bounds.height), viewport \(outer.contentView.bounds.height)")
RunLoop.current.run(until:Date().addingTimeInterval(0.2))
print("Settings scrolling and pinned layout passed")
store.agents = ["claude":["installed":true],"codex":["installed":true]]
let gameWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:860),styleMask:[.titled],backing:.buffered,defer:false)
let office = OfficeScene(frame:.zero)
let gameHost = NSHostingView(rootView:OfficeRoot(store:store,scene:office)); gameWindow.contentView = gameHost; gameWindow.orderFrontRegardless()
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
precondition(office.bounds.width < gameHost.bounds.width - 300, "chat must occupy its own right column")
print("Right chat column layout passed")
store.selectedID = "r1"
store.room = ["id":"r1", "title":"งาน", "status":"waiting", "waiting":["kind":"ask", "from":"codex"], "messages":[["id":"q1", "from":"codex", "text":"ใช้ A หรือ B?"]]]
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
precondition(gameWindow.attachedSheet != nil, "question must pop up as a sheet")
store.drafts["r1:q1:ask"] = "ร่างคำตอบ"
gameWindow.attachedSheet!.cancelOperation(nil); RunLoop.current.run(until:Date().addingTimeInterval(0.5)); precondition(gameWindow.attachedSheet == nil, "Esc closes the question"); store.room?["title"] = "งาน "
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
precondition(gameWindow.attachedSheet == nil, "the same question pops up only once")
precondition(store.drafts["r1:q1:ask"] == "ร่างคำตอบ", "draft survives closing")
store.room?["messages"] = [["id":"q1", "from":"codex", "text":"ใช้ A หรือ B?"], ["id":"q2", "from":"codex", "text":"แล้ว C ล่ะ?"]]
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
precondition(gameWindow.attachedSheet != nil, "a new question pops up again")
precondition(store.pendingQuestion() != nil, "reopen button shows while the question waits")
store.drafts["r1:q2:ask"] = "C"
var sendError: String?
store.answer("r1:q2:ask", "api/rooms/r1/message", ["text":"C"]) { sendError = $0 }
let sendEnd = Date().addingTimeInterval(3); while sendError == nil && Date() < sendEnd { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
precondition(sendError != nil && store.drafts["r1:q2:ask"] == "C" && gameWindow.attachedSheet != nil, "failed send keeps the popup and the answer")
print("Question send failure keeps the answer passed")
store.room?["status"] = "running"
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
precondition(gameWindow.attachedSheet == nil, "popup closes once the team is working again")
let structured: JSONObject = ["id":"p9", "from":"codex", "status":"pending", "source":"codex", "questions":[["id":"a", "header":"", "question":"เลือก?", "multiSelect":false, "options":[["id":"o1", "label":"X", "description":"d"]]]]]
store.room = ["id":"r1", "title":"งาน", "status":"running", "running":["agent":"codex"], "messages":[], "questions":[structured]]
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
precondition(gameWindow.attachedSheet != nil, "structured question pops up while the team is running")
var picked = AnswerDraft(); picked.choose("o1", in: "a", multi: false)
store.answerDrafts["p9"] = picked
gameWindow.attachedSheet!.cancelOperation(nil); RunLoop.current.run(until:Date().addingTimeInterval(0.5))
precondition(gameWindow.attachedSheet == nil && store.answerDrafts["p9"] == picked && store.pendingQuestion() != nil, "closing keeps the prompt pending and the draft intact")
var structuredError: String?
store.submitAnswers(store.pendingQuestion()!) { structuredError = $0 }
let structuredEnd = Date().addingTimeInterval(3); while structuredError == nil && Date() < structuredEnd { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
precondition(structuredError != nil && store.answerDrafts["p9"] == picked, "failed structured send keeps the answers")
var expiredPrompt = structured; expiredPrompt["status"] = "expired"; store.room?["questions"] = [expiredPrompt]
precondition(store.pendingQuestion() == nil, "expired prompt cannot be reopened or sent")
print("Structured question popup, draft and failure handling passed")
let blocks = DocumentView.blocks("# แผน\nข้อความ\n```mermaid\nflowchart TD\n  A-->B\n```\nจบ")
precondition(blocks.count == 3 && blocks[0].language == nil && blocks[0].text == "# แผน\nข้อความ" && blocks[1].language == "mermaid" && blocks[1].text == "flowchart TD\n  A-->B" && blocks[2].text == "จบ", "documents split Markdown and Mermaid source")
let docWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:520),styleMask:[.titled],backing:.buffered,defer:false)
docWindow.contentView = NSHostingView(rootView:VStack { DocumentView(document:["title":"แผนงาน", "path":"/tmp/plan.md", "content":"# แผน\n```mermaid\nflowchart TD\nA-->B\n```"]); WorkProgressView(room:["id":"w", "workflow":["phase":"working", "tasks":[["id":"t", "owner":"codex", "assignment":"งาน", "files":["/p/a"], "dependsOn":["x"], "status":"waiting"]], "documents":[["id":"d", "title":"แผนงาน", "path":"/tmp/plan.md"]]]]) })
docWindow.orderFrontRegardless(); RunLoop.current.run(until:Date().addingTimeInterval(0.3)); docWindow.orderOut(nil)
print("Document viewer and workflow panel render passed")
var chatRoom: JSONObject = ["id":"c", "messages":(0..<40).map { ["id":"m\($0)", "from":"codex", "text":"ข้อความ \($0)"] as JSONObject }, "live":["agent":"codex", "steps":[["kind":"text", "body":"a"]]]]
let chatWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:400),styleMask:[.titled],backing:.buffered,defer:false)
let chatHost = NSHostingView(rootView:ConversationView(room:chatRoom)); chatWindow.contentView = chatHost; chatWindow.orderFrontRegardless()
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
func chatScroll() -> NSScrollView { scrolls(chatHost).first! }
func gap() -> CGFloat { let s = chatScroll(); return s.documentView!.bounds.height - s.contentView.bounds.maxY }
func grow() { var live = chatRoom["live"] as! JSONObject; var step = (live["steps"] as! [JSONObject])[0]; step["body"] = (step["body"] as! String) + String(repeating: "บรรทัดใหม่\n", count: 4); live["steps"] = [step]; chatRoom["live"] = live; chatHost.rootView = ConversationView(room:chatRoom); RunLoop.current.run(until:Date().addingTimeInterval(0.4)) }
precondition(gap() < 20, "chat opens at the end")
for _ in 0..<3 { grow() }
precondition(gap() < 20, "chat follows streaming text at the end: gap \(gap())")
print("Chat follow scrolling passed")
let history = chatScroll(); history.contentView.scroll(to: NSPoint(x: 0, y: 0)); history.reflectScrolledClipView(history.contentView)
RunLoop.current.run(until:Date().addingTimeInterval(0.2))
grow()
precondition(gap() > 100, "streaming must not pull the reader away from older history")
print("Reading older chat history is preserved passed")
print("Question popup passed")
let rendered = MessageView.markdown("## หัวข้อ\n**ตัวหนา** และ `code`")
precondition(String(rendered.characters) == "หัวข้อ\nตัวหนา และ code", "chat must not show raw Markdown markers")
print("Chat Markdown rendering passed")

} }
