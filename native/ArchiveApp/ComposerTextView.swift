import AppKit
import SwiftUI

// The composer's text view. AppKit directly, because SwiftUI's TextEditor
// offers no spell-checking control and swallows pasted or dropped files.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var spellCheck: Bool
    var autocorrect: Bool
    var placeholder: String
    var onHeightChange: (CGFloat) -> Void
    var onFocusChange: (Bool) -> Void
    var onAttachFiles: ([URL]) -> Void
    var onAttachData: (Data, String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.postsFrameChangedNotifications = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        context.coordinator.textView = textView
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged), name: NSView.frameDidChangeNotification, object: textView)
        apply(to: textView, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        apply(to: textView, coordinator: context.coordinator)
    }

    private func apply(to textView: ComposerNSTextView, coordinator: Coordinator) {
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let location = min(selection.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.needsDisplay = true
            coordinator.reportHeight()
        }
        textView.isEditable = isEditable
        textView.isContinuousSpellCheckingEnabled = spellCheck
        textView.isAutomaticSpellingCorrectionEnabled = autocorrect
        textView.placeholder = placeholder
        textView.attachFiles = onAttachFiles
        textView.attachData = onAttachData
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        private var lastHeight: CGFloat = 0
        init(parent: ComposerTextView) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }
        @objc func frameChanged(_ notification: Notification) { reportHeight() }

        func reportHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            let report = parent.onHeightChange
            DispatchQueue.main.async { report(height) }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = ""
    var attachFiles: (([URL]) -> Void)?
    var attachData: ((Data, String) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.tertiaryLabelColor]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // Files and images on the pasteboard become attachments; text pastes as usual.
    override func paste(_ sender: Any?) {
        if handleAttachments(from: NSPasteboard.general) { return }
        super.paste(sender)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if carriesAttachments(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if carriesAttachments(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if handleAttachments(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || (pasteboard.string(forType: .string) == nil && (pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil))
    }
    private func handleAttachments(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attachFiles?(urls)
            return true
        }
        guard pasteboard.string(forType: .string) == nil else { return false }
        if let png = pasteboard.data(forType: .png) {
            attachData?(png, "Pasted image.png")
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            attachData?(png, "Pasted image.png")
            return true
        }
        return false
    }
}
