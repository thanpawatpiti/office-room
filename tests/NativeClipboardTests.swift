import Cocoa
import SwiftUI

@main struct NativeClipboardTests {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let board = NSPasteboard.general
        let original = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType:type).map { (type,$0) } } }
        var ownVersion = board.changeCount
        defer {
            if board.changeCount == ownVersion {
                let items = original.map { values -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in values { item.setData(data,forType:type) }; return item }
                board.clearContents(); board.writeObjects(items)
            }
        }
        let menu = NSMenu(); let edit = NSMenu(); let root = NSMenuItem(); root.submenu = edit; menu.addItem(root)
        let paste = NSMenuItem(title:"วาง",action:#selector(NativeEditActions.paste(_:)),keyEquivalent:"v"); paste.target = NativeEditActions.shared; paste.keyEquivalentModifierMask = .command; edit.addItem(paste); app.mainMenu = menu
        func editors(_ view:NSView)->[NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        for height:CGFloat in [78,140] {
            var text = ""; var images:[DraftImage] = []
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:300),styleMask:[.titled],backing:.buffered,defer:false)
            let host = NSHostingView(rootView:PromptInput(text:Binding(get:{text},set:{text=$0}),images:Binding(get:{images},set:{images=$0}),title:"โจทย์",height:height))
            window.contentView=host; window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until:Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded()
            let editor = editors(host).first as! PromptTextView
            precondition(editor.frame.height >= height - 10 && editor.frame.width > 100, "editor must be clickable")
            precondition(window.makeFirstResponder(editor))
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"v",charactersIgnoringModifiers:"v",isARepeat:false,keyCode:9)!
            board.clearContents();board.setString("โจทย์ภาษาไทย\nบรรทัดสอง",forType:.string);ownVersion=board.changeCount
            precondition(editor.performKeyEquivalent(with:event)); precondition(text.contains("บรรทัดสอง"))
            board.clearContents();board.setString(" ทดสอบเมนู",forType:.string);ownVersion=board.changeCount
            precondition(NativeEditActions.shared.focusedEditor === editor)
            precondition(menu.performKeyEquivalent(with:event));precondition(text.contains("ทดสอบเมนู"))
            let image=NSImage(size:NSSize(width:16,height:16),flipped:false){r in NSColor.red.setFill();r.fill();return true}
            board.clearContents();board.writeObjects([image]);ownVersion=board.changeCount
            precondition(editor.performKeyEquivalent(with:event));precondition(images.count == 1 && !images[0].png.isEmpty)
            editor.isEditable = false; editor.paste(nil); precondition(images.count == 1, "disabled editor must preserve upload draft"); editor.isEditable = true
            precondition(text.contains("โจทย์ภาษาไทย"), "image paste must preserve draft text")
            window.orderOut(nil)
        }
        print("Chat/task native editors: Command-V, menu paste, Thai multiline text and clipboard images passed")
    }
}
