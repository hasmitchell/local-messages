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
    /// A new value puts the caret in the composer (opening a conversation, Reply, Restore as Draft).
    var focusToken: UUID
    var actions: ComposerEditorActions
    var placeholder: String
    var onSubmit: () -> Void
    var onHeightChange: (CGFloat) -> Void
    var onFocusChange: (Bool) -> Void
    var onAttachFiles: ([URL]) -> Void
    var onAttachData: (Data, String) -> Void
    /// An image that needs converting first (TIFF or PDF on the pasteboard).
    var onAttachImage: (Data) -> Void = { _ in }

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
            // Dictation belongs to the conversation it was started in.
            if actions.dictating { Task { @MainActor [actions] in actions.stopDictation() } }
        }
        if contextChanged || textView.string != text {
            // Programmatic draft changes (including a successful send) must
            // not retain undo operations targeting the previous text.
            textView.undoManager?.removeAllActions()
            let wasEmpty = textView.string.isEmpty
            let selection = textView.selectedRange()
            textView.string = text
            // Restored or switched-in text puts the caret at its end, ready to go on typing.
            let location = contextChanged || wasEmpty ? (text as NSString).length : min(selection.location, (text as NSString).length)
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
        textView.attachImage = onAttachImage
        textView.cancelled = { [actions] in actions.dictationEnded() }
        // Focus is reported when the caret arrives, not at the first keystroke.
        // Async: makeFirstResponder can run inside a SwiftUI update.
        textView.focusChanged = { [onFocusChange] focused in DispatchQueue.main.async { onFocusChange(focused) } }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.isEditable, let window = textView.window, window.firstResponder !== textView else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var contextID: String?
        /// Starts at the current token, so a freshly built composer does not take focus by itself.
        var focusToken: UUID
        weak var textView: ComposerNSTextView?
        private var lastHeight: CGFloat = 0
        init(parent: ComposerTextView) { self.parent = parent; focusToken = parent.focusToken }
        deinit { NotificationCenter.default.removeObserver(self) }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.actions.noteActivity()
            reportHeight()
        }
        func textDidEndEditing(_ notification: Notification) { parent.actions.dictationEnded() }
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
    var attachImage: ((Data) -> Void)?
    /// Escape also ends system dictation.
    var cancelled: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusChanged?(true) }
        return became
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged?(false) }
        return resigned
    }
    override func cancelOperation(_ sender: Any?) {
        cancelled?()
        super.cancelOperation(sender)
    }

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
            || (pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) && !PastedImage.prefersText(pasteboard))
    }
    // Files first; otherwise any image the system can read (screenshot tools
    // vary in the types they offer, and some add a text flavour as well).
    private func handleAttachments(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attachFiles?(urls)
            return true
        }
        // Word, Excel, Pages and Numbers add a picture of the selection beside its text.
        if PastedImage.prefersText(pasteboard) { return false }
        if let (data, name) = PastedImage.original(from: pasteboard) {
            attachData?(data, name)
            return true
        }
        // Only TIFF or PDF: converted away from the main thread by the model,
        // which keeps Send waiting until the photo is attached.
        guard let raw = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .pdf), let attachImage else { return false }
        attachImage(raw)
        return true
    }
}

enum PastedImage {
    /// Rich text, or text whose only picture is a PDF rendering, is pasted as text.
    static func prefersText(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard types.contains(.string) else { return false }
        let bitmaps: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic"), .init("com.compuserve.gif")]
        return types.contains(.rtf) || types.contains(.rtfd) || !types.contains(where: bitmaps.contains)
    }
    /// The image as its source compressed it, so a photo is neither re-encoded nor inflated.
    static func original(from pasteboard: NSPasteboard) -> (Data, String)? {
        let kinds: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.init("public.jpeg"), "jpg"), (.init("public.heic"), "heic"), (.init("com.compuserve.gif"), "gif")]
        for (type, ext) in kinds {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return (data, "Pasted image." + ext) }
        }
        return nil
    }
    /// PNG for images with transparency, JPEG otherwise.
    nonisolated static func compressed(from image: NSImage) -> (data: Data, name: String)? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        if bitmap.hasAlpha, let png = bitmap.representation(using: .png, properties: [:]) { return (png, "Pasted image.png") }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]).map { ($0, "Pasted image.jpg") }
    }
}

@MainActor final class ComposerEditorActions: NSObject, ObservableObject {
    weak var textView: ComposerNSTextView?
    func showEmojiPicker() {
        guard let textView, textView.isEditable, let window = textView.window else { return }
        window.makeFirstResponder(textView)
        NSApp.orderFrontCharacterPalette(nil)
    }

    // Voice input is the system's own Dictation (Edit ▸ Start Dictation), so it
    // follows the user's language, microphone and on-device settings, and needs
    // no microphone permission of its own. AppKit reports no dictation state, so
    // `dictating` is this button's best knowledge: it clears when the composer
    // loses focus, a message is sent, Escape is pressed, the app goes to the
    // background, or nothing has been dictated for a while (the system stops
    // listening by itself after a silence).
    @Published private(set) var dictating = false
    private var lastDictation = Date()
    private var idleCheck: Task<Void, Never>?
    override init() {
        super.init()
        // Selector observers are removed automatically when this object goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
    }
    @objc private func appResigned(_ note: Notification) { dictationEnded() }

    func toggleDictation() { dictating ? stopDictation() : startDictation() }
    func startDictation() {
        guard let textView, textView.isEditable, let window = textView.window else { return }
        window.makeFirstResponder(textView)
        guard NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) else { return }
        dictating = true
        lastDictation = Date()
        idleCheck?.cancel()
        idleCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.dictating else { return }
                if Date().timeIntervalSince(self.lastDictation) > 30 { self.dictationEnded(); return }
            }
        }
    }
    /// Ends dictation, keeping what has been transcribed.
    func stopDictation() {
        guard dictating else { return }
        NSApp.sendAction(Selector(("stopDictation:")), to: nil, from: nil)
        dictationEnded()
    }
    /// Text arrived while listening: the system is still dictating.
    func noteActivity() { if dictating { lastDictation = Date() } }
    func dictationEnded() {
        idleCheck?.cancel(); idleCheck = nil
        if dictating { dictating = false }
    }
}
