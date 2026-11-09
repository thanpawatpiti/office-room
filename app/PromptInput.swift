import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct DraftImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let png: Data
    var name: String { "ภาพแนบ.png" }
    static func make(_ image: NSImage) -> DraftImage? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]), data.count <= 8 * 1024 * 1024 else { return nil }
        return DraftImage(image: image, png: data)
    }
}

final class PromptScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let size = contentView.bounds.size
        editor.minSize = NSSize(width: 0, height: size.height)
        if editor.frame.width != size.width || editor.frame.height < size.height {
            editor.setFrameSize(NSSize(width: size.width, height: max(editor.frame.height, size.height)))
        }
    }
}
final class PromptTextView: NSTextView {
    var imagePaste: (([NSImage]) -> Void)?
    var submit: (() -> Void)?
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let board = NSPasteboard.general
        if board.types?.contains(.png) == true || board.types?.contains(.tiff) == true {
            if let images = NSImage(pasteboard: board) { imagePaste?([images]); return }
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.compactMap { NSImage(contentsOf: $0) }
            if !images.isEmpty { imagePaste?(images); return }
        }
        pasteAsPlainText(sender)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift] {
            switch event.keyCode {
            case 9: paste(nil); return true
            case 0 where flags == .command: selectAll(nil); return true
            case 8 where flags == .command: copy(nil); return true
            case 7 where flags == .command: cut(nil); return true
            case 6: if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }; return true
            case 36: submit?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
struct NativePromptEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    var accessibilityName: String
    var autofocus = false
    var pasteImages: ([NSImage]) -> Void
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PromptScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100)); editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true; editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 14); editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 10, height: 10); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel(accessibilityName); editor.delegate = context.coordinator
        scroll.documentView = editor
        if autofocus { DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) } }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PromptTextView else { return }
        editor.isEditable = isEnabled
        if editor.string != text { editor.string = text }
        editor.imagePaste = pasteImages; editor.submit = submit
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePromptEditor
        init(_ parent: NativePromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
    }
}
struct PromptInput: View {
    @Binding var text: String
    @Binding var images: [DraftImage]
    var title: String
    var height: CGFloat = 120
    var autofocus = false
    var submit: () -> Void = {}
    @NativeState private var imageError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                NativePromptEditor(text: $text, accessibilityName: title, autofocus: autofocus, pasteImages: addImages, submit: submit).frame(height: height)
                if text.isEmpty { Text(title).font(.body).foregroundStyle(.secondary).padding(12).allowsHitTesting(false) }
            }.background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.15)))
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { ForEach(images) { item in
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: item.image).resizable().scaledToFit().frame(width: 76, height: 62).padding(4).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            Button { images.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("นำภาพออก")
                        }
                    } }
                }
            }
            HStack {
                Button { chooseImages() } label: { Label("แนบรูป", systemImage: "photo.badge.plus") }.buttonStyle(.borderless)
                Text("⌘V วางข้อความหรือรูป · ⌘Enter ส่ง").font(.caption2).foregroundStyle(.secondary)
            }
            if let error = imageError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    func addImages(_ values: [NSImage]) {
        imageError = nil
        guard images.count + values.count <= 4 else { imageError = "แนบรูปได้ครั้งละไม่เกิน 4 รูป"; return }
        let converted = values.compactMap(DraftImage.make)
        guard converted.count == values.count else { imageError = "รูปต้องมีขนาดไม่เกิน 8 MB ต่อรูป"; return }
        images += converted
    }
    func chooseImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addImages(panel.urls.compactMap { NSImage(contentsOf: $0) }) }
    }
}

// Target the focused native editor explicitly, including the editor inside a sheet.
final class NativeEditActions: NSObject, NSMenuItemValidation {
    static let shared = NativeEditActions()
    var focusedEditor: NSTextView? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows where window.isVisible {
            let target = window.attachedSheet ?? window
            if let editor = target.firstResponder as? NSTextView { return editor }
            if let field = target.firstResponder as? NSTextField, let editor = field.currentEditor() as? NSTextView { return editor }
        }
        return nil
    }
    @objc func paste(_ sender: Any?) { focusedEditor?.paste(sender) }
    @objc func copy(_ sender: Any?) { focusedEditor?.copy(sender) }
    @objc func cut(_ sender: Any?) { focusedEditor?.cut(sender) }
    @objc func selectAll(_ sender: Any?) { focusedEditor?.selectAll(sender) }
    @objc func undo(_ sender: Any?) { focusedEditor?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { focusedEditor?.undoManager?.redo() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { focusedEditor != nil }
}
extension OfficeStore {
    func uploadImages(_ images: [DraftImage], done: @escaping (Result<[JSONObject], Error>) -> Void) {
        var result: [JSONObject] = []
        func next(_ index: Int) {
            if index == images.count { done(.success(result)); return }
            request("api/images", method: "POST", body: ["name": images[index].name, "data": images[index].png.base64EncodedString()]) { response in
                switch response { case .failure(let error): done(.failure(error)); case .success(let image): result.append(image); next(index + 1) }
            }
        }
        next(0)
    }
}
