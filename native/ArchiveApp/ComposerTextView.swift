import AppKit
import SwiftUI

// The composer's text view. AppKit directly, because SwiftUI's TextEditor
// offers no spell-checking control and swallows pasted or dropped files.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var spellCheck: Bool
    var autocorrect: Bool
    var emojiShortcuts: Bool
    var contextID: String
    var actions: ComposerEditorActions
    var placeholder: String
    var onSubmit: () -> Void
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
        actions.textView = textView
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
        actions.textView = textView
        let contextChanged = coordinator.contextID != contextID
        if contextChanged {
            coordinator.contextID = contextID
        }
        if contextChanged || textView.string != text {
            // Programmatic draft changes (including a successful send) must
            // not retain undo operations targeting the previous text.
            textView.undoManager?.removeAllActions()
            let selection = textView.selectedRange()
            textView.string = text
            let location = contextChanged ? (text as NSString).length : min(selection.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.needsDisplay = true
            coordinator.reportHeight()
        }
        textView.emojiShortcutsEnabled = emojiShortcuts
        textView.isEditable = isEditable
        textView.isContinuousSpellCheckingEnabled = spellCheck
        textView.isAutomaticSpellingCorrectionEnabled = autocorrect
        textView.placeholder = placeholder
        textView.submit = onSubmit
        textView.attachFiles = onAttachFiles
        textView.attachData = onAttachData
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var contextID: String?
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
    var emojiShortcutsEnabled = true
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let composing = hasMarkedText()
        super.insertText(insertString, replacementRange: replacementRange)
        guard isEditable, emojiShortcutsEnabled, !composing, !hasMarkedText(),
              let inserted = insertString as? String, inserted.utf16.count == 1,
              selectedRange().length == 0,
              let replacement = EmojiShortcuts.replacement(in: string, caret: selectedRange().location) else { return }
        // Give Undo a replacement to undo, rather than rewriting the full draft.
        breakUndoCoalescing()
        // Typing the closing character and replacing the shortcut happen in
        // one key event. End its automatic group so Undo restores the shortcut.
        if editingUndoManager.groupingLevel == 1 {
            editingUndoManager.endUndoGrouping()
            editingUndoManager.beginUndoGrouping()
        }
        super.insertText(replacement.emoji, replacementRange: replacement.range)
        breakUndoCoalescing()
    }
    /// Return sends; Shift-Return (or Option-Return) adds a new line.
    var submit: (() -> Void)?
    private var keyModifiers: NSEvent.ModifierFlags = []
    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        defer { keyModifiers = [] }
        super.keyDown(with: event)
    }
    override func doCommand(by selector: Selector) {
        let newline = [#selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertParagraphSeparator(_:)), #selector(insertNewlineIgnoringFieldEditor(_:))]
        guard let submit, newline.contains(selector), !hasMarkedText() else { return super.doCommand(by: selector) }
        let modifiers = keyModifiers.intersection([.shift, .option])
        // A plain newline character, never U+2028, whichever binding produced it.
        if !modifiers.isEmpty { insertNewlineIgnoringFieldEditor(nil) }
        else if selector == #selector(insertNewline(_:)) { submit() }
        else { super.doCommand(by: selector) }
    }
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
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }
    // Files first; otherwise any image the system can read (screenshot tools
    // vary in the types they offer, and some add a text flavour as well).
    private func handleAttachments(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attachFiles?(urls)
            return true
        }
        if let png = PastedImage.png(from: pasteboard) {
            attachData?(png, "Pasted image.png")
            return true
        }
        return false
    }
}

enum PastedImage {
    static func png(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first else { return nil }
        return png(from: image)
    }
    static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor final class ComposerEditorActions: ObservableObject {
    weak var textView: ComposerNSTextView?
    func showEmojiPicker() {
        guard let textView, textView.isEditable, let window = textView.window else { return }
        window.makeFirstResponder(textView)
        NSApp.orderFrontCharacterPalette(nil)
    }
}
