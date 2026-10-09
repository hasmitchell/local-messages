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
        // Only a change made outside the text view (a send clearing it, a
        // restored draft, another conversation) is written into it. Words that
        // Dictation or an input method is still composing exist only in the
        // view, as marked text AppKit does not report; comparing with the
        // view's own string would wipe them on the next redraw.
        if contextChanged || text != coordinator.lastText {
            coordinator.lastText = text
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
        textView.cancelled = { [actions] in actions.stopDictation() }
        textView.finishDictation = { [actions] in
            guard actions.dictating else { return false }
            actions.stopDictation()
            return true
        }
        textView.textActivity = { [actions] in actions.noteActivity() }
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
        /// The draft text as the model last had it: set when the view reports a
        /// change and when the model's text is written into the view.
        var lastText: String?
        /// Starts at the current token, so a freshly built composer does not take focus by itself.
        var focusToken: UUID
        weak var textView: ComposerNSTextView?
        private var lastHeight: CGFloat = 0
        init(parent: ComposerTextView) { self.parent = parent; focusToken = parent.focusToken }
        deinit { NotificationCenter.default.removeObserver(self) }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            lastText = textView.string
            parent.text = textView.string
            parent.actions.noteActivity()
            reportHeight()
        }
        func textDidEndEditing(_ notification: Notification) { parent.actions.stopDictation() }
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

    /// Dictation or an input method changed the text it is still composing.
    var textActivity: (() -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
        textActivity?()
    }
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
    /// Ends dictation if it is running; true when it was.
    var finishDictation: (() -> Bool)?
    private var keyModifiers: NSEvent.ModifierFlags = []
    override func keyDown(with event: NSEvent) {
        // Return while dictating finishes the dictation and keeps the words;
        // the next Return sends. Taken before the input context sees the key.
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
           finishDictation?() == true { return }
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

    // Voice input. On macOS 26 it is Apple's on-device speech model
    // (OnDeviceDictation): this object knows exactly when it listens, shows
    // still-changing words as grey marked text and commits settled ones.
    // Otherwise, or when the user picks it in Settings, it is the system's own
    // Dictation (Edit ▸ Start Dictation). AppKit reports no state for that, so
    // `dictating` is then best knowledge: it clears when the composer loses
    // focus, a message is sent, Escape is pressed, the app goes to the
    // background, or nothing has been dictated for a while.
    @Published private(set) var dictating = false
    /// Preparing (microphone permission, the one-time model download) or why voice input stopped.
    @Published private(set) var voiceStatus: String?
    /// Microphone level for the button, kept apart so it redraws only the button.
    let meter = VoiceMeter()
    private var lastDictation = Date()
    private var idleCheck: Task<Void, Never>?
    private var session: AnyObject?
    private var stopping: Task<Void, Never>?
    private var savedMarkedAttributes: [NSAttributedString.Key: Any]?
    override init() {
        super.init()
        // Selector observers are removed automatically when this object goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
    }
    // The microphone never stays on behind other windows. While the on-device
    // model is still preparing, the app loses focus to the microphone prompt:
    // that is not a reason to stop.
    @objc private func appResigned(_ note: Notification) {
        if #available(macOS 26, *), let dictation = session as? OnDeviceDictation, !dictation.listening { return }
        stopDictation()
    }

    static var onDeviceAvailable: Bool {
        if #available(macOS 26, *) { return OnDeviceDictation.isAvailable }
        return false
    }
    private var usesOnDevice: Bool { Self.onDeviceAvailable && UserDefaults.standard.string(forKey: "voiceInput") != "dictation" }

    func toggleDictation() { dictating ? stopDictation() : startDictation() }
    func startDictation() {
        guard !dictating, stopping == nil, let textView, textView.isEditable, let window = textView.window else { return }
        let focused = window.firstResponder === textView
        if !focused { window.makeFirstResponder(textView) }
        dictating = true
        voiceStatus = nil
        lastDictation = Date()
        if #available(macOS 26, *), usesOnDevice { startOnDevice(textView) } else { startSystemDictation(textView, focused: focused) }
        watchIdle()
    }
    private func watchIdle() {
        idleCheck?.cancel()
        idleCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.dictating else { return }
                // A minute without words: stop listening rather than leave the microphone on.
                if Date().timeIntervalSince(self.lastDictation) > (self.session == nil ? 30 : 60) { self.stopDictation(); return }
            }
        }
    }
    private func startDictationWithSystem() {
        guard !dictating, let textView, textView.isEditable, let window = textView.window else { return }
        let focused = window.firstResponder === textView
        if !focused { window.makeFirstResponder(textView) }
        dictating = true
        lastDictation = Date()
        startSystemDictation(textView, focused: focused)
        watchIdle()
    }
    private func startSystemDictation(_ textView: ComposerNSTextView, focused: Bool) {
        // Dictation writes into whichever input context is current when it
        // starts. After a focus change that is settled on the next turn.
        let begin = { [weak self, weak textView] in
            textView?.inputContext?.activate()
            if !NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) { self?.dictationEnded() }
        }
        if focused { begin() } else { DispatchQueue.main.async { MainActor.assumeIsolated { begin() } } }
    }
    @available(macOS 26, *)
    private func startOnDevice(_ textView: ComposerNSTextView) {
        let dictation = OnDeviceDictation()
        attach(dictation, to: textView)
        Task { [weak self] in
            do { try await dictation.start() }
            catch { self?.onDeviceFailed(error) }
        }
    }
    @available(macOS 26, *)
    private func attach(_ dictation: OnDeviceDictation, to textView: ComposerNSTextView) {
        session = dictation
        // Words still being decided read grey; they turn black once settled.
        savedMarkedAttributes = textView.markedTextAttributes
        textView.markedTextAttributes = [.foregroundColor: NSColor.secondaryLabelColor]
        dictation.onVolatile = { [weak self] text in self?.compose(text, settled: false) }
        dictation.onFinal = { [weak self] text in self?.compose(text, settled: true) }
        dictation.onStatus = { [weak self, weak dictation] status in
            // Only the current session speaks.
            guard let self, let dictation, self.session === dictation, self.voiceStatus != status else { return }
            self.voiceStatus = status
        }
        dictation.onLevel = { [weak self] level in self?.meter.set(level) }
        dictation.onEnded = { [weak self] error in self?.onDeviceEnded(error) }
    }
    #if ARCHIVE_TESTING
    /// Dictates a recording into the composer through the same path as the microphone.
    @available(macOS 26, *)
    func dictateForTesting(file: URL) async throws {
        guard let textView else { return }
        let dictation = OnDeviceDictation()
        attach(dictation, to: textView)
        dictating = true
        defer { endOnDevice(); dictationEnded() }
        try await dictation.transcribe(file: file)
    }
    #endif
    /// Shows words the model is still deciding as marked text, or commits settled ones.
    private func compose(_ text: String, settled: Bool) {
        // Still accepted while stopping: the last words arrive after the microphone is off.
        guard let textView, session != nil else { return }
        lastDictation = Date()
        let words = spaced(text, in: textView)
        let anywhere = NSRange(location: NSNotFound, length: 0)
        if settled {
            if !words.isEmpty || textView.hasMarkedText() { textView.insertText(words, replacementRange: anywhere) }
        } else {
            textView.setMarkedText(words, selectedRange: NSRange(location: (words as NSString).length, length: 0), replacementRange: anywhere)
        }
    }
    /// One space between what is already there and the new words, none before punctuation.
    private func spaced(_ text: String, in textView: NSTextView) -> String {
        let words = String(text.drop(while: \.isWhitespace))
        guard let first = words.first else { return "" }
        let position = textView.hasMarkedText() ? textView.markedRange().location : textView.selectedRange().location
        guard position > 0, position <= (textView.string as NSString).length else { return words }
        let before = (textView.string as NSString).substring(with: NSRange(location: position - 1, length: 1))
        if before.allSatisfy(\.isWhitespace) || ".,!?;:)]}…".contains(first) { return words }
        return " " + words
    }
    @available(macOS 26, *)
    private func onDeviceFailed(_ error: Error) {
        let failure = error as? OnDeviceDictation.Failure
        endOnDevice()
        dictationEnded()
        if failure == .microphoneDenied || failure == .noMicrophone { showVoiceStatus(failure?.localizedDescription); return }
        // macOS Dictation still works. A language the model lacks switches
        // over for good; anything else (a failed download) only this time.
        if failure == .unsupportedLanguage { UserDefaults.standard.set("dictation", forKey: "voiceInput") }
        startDictationWithSystem()
        showVoiceStatus(failure?.localizedDescription ?? "The on-device speech model couldn’t start, so this uses macOS Dictation.")
    }
    @available(macOS 26, *)
    private func onDeviceEnded(_ error: Error?) {
        endOnDevice()
        dictationEnded()
        if error != nil { showVoiceStatus("Voice input stopped unexpectedly. Click the microphone to try again.") }
    }
    /// Keeps whatever was still being decided, and puts the composer back as it was.
    private func endOnDevice() {
        if let textView {
            if textView.hasMarkedText() {
                let pending = (textView.string as NSString).substring(with: textView.markedRange())
                textView.insertText(pending, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            if let savedMarkedAttributes { textView.markedTextAttributes = savedMarkedAttributes }
        }
        savedMarkedAttributes = nil
        session = nil
        meter.set(0)
        voiceStatus = nil
    }
    private func showVoiceStatus(_ text: String?) {
        voiceStatus = text
        guard let text else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.voiceStatus == text { self?.voiceStatus = nil }
        }
    }
    /// Ends dictation, keeping what has been transcribed.
    func stopDictation() {
        guard dictating else { return }
        if #available(macOS 26, *), let dictation = session as? OnDeviceDictation {
            dictationEnded()
            stopping = Task { [weak self] in
                await dictation.stop()
                self?.endOnDevice()
                self?.stopping = nil
            }
            return
        }
        NSApp.sendAction(Selector(("stopDictation:")), to: nil, from: nil)
        dictationEnded()
    }
    /// Stops listening and waits until the last words are in the composer.
    func finishDictation() async {
        stopDictation()
        if let stopping { await stopping.value; return }
        // macOS Dictation delivers its last words shortly after it stops.
        for _ in 0..<20 where textView?.hasMarkedText() == true { try? await Task.sleep(for: .milliseconds(50)) }
    }
    /// Text arrived while listening.
    func noteActivity() { if dictating { lastDictation = Date() } }
    func dictationEnded() {
        idleCheck?.cancel(); idleCheck = nil
        if dictating { dictating = false }
    }
}

/// The microphone level while the on-device model listens, for the button only.
@MainActor final class VoiceMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    func set(_ value: Float) {
        // Coarse steps: a redraw only when the change is visible.
        let stepped = (value * 10).rounded() / 10
        if stepped != level { level = stepped }
    }
}
