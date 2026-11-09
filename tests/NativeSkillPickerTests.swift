import Cocoa
import SwiftUI

@main struct NativeSkillPickerTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = OfficeStore(base: URL(string:"http://127.0.0.1:1")!)
        store.skillCatalog = [
            ["id":"engineering", "name":"senior-fullstack", "description":"Implement frontend and backend", "source":"ส่วนตัว"],
            ["id":"qa", "name":"senior-qa", "description":"ทดสอบระบบและวางแผน QA", "source":"โปรเจกต์ demo"],
            ["id":"ux", "name":"ui-ux-pro-max", "description":"Visual interface design", "source":"ส่วนตัว"]
        ]
        precondition(SkillPickerView.matching(store.skillCatalog,search:"FRONTEND").map(\.roomID) == ["engineering"])
        precondition(SkillPickerView.matching(store.skillCatalog,search:"ทดสอบ").map(\.roomID) == ["qa"])
        precondition(SkillPickerView.matching(store.skillCatalog,search:"no match").isEmpty)
        var selected: Set<String> = []
        let picker = SkillPickerView(store:store,selected:Binding(get:{selected},set:{selected=$0}),reload:{})
        let host = NSHostingView(rootView:picker)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:450),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=host;window.orderFrontRegardless()
        RunLoop.current.run(until:Date().addingTimeInterval(0.5))
        // Send native window events to the two visible fixture checkboxes.
        func click(_ topY: CGFloat) {
            let point = NSPoint(x:24,y:host.isFlipped ? topY : host.bounds.height-topY)
            let location = host.convert(point, to:nil)
            for type: NSEvent.EventType in [.leftMouseDown,.leftMouseUp] {
                let event=NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                window.sendEvent(event)
            }
            RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        }
        click(153)
        click(218)
        precondition(selected == ["engineering", "qa"],"checking two native skill rows must select two skill IDs")
        click(153)
        precondition(selected == ["qa"],"unchecking a skill must preserve the other selection")
        precondition(host.bounds.width == 540 && host.bounds.height == 450)
        print("Native skill search, multiple checkbox selection and removal passed")
    }
}
