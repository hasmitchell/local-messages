import AppKit

@main struct ComposerTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func main() {
        do { try run(); print("Composer checks passed: shortcuts, token boundaries, Unicode caret, selections, paste, IME, undo, disabled conversion, and Return/Shift-Return.") }
        catch { print("Composer check failed: \(error)"); exit(1) }
    }
    @MainActor static func run() throws {
        _ = NSApplication.shared
        for (input, emoji) in [(":)", "🙂"), ("Great :-)", "🙂"), (";)", "😉"), (":D", "😃"), ("<3", "❤️"), ("\n:(", "🙁"), ("😀 :)", "🙂")] {
            let found = EmojiShortcuts.replacement(in: input, caret: (input as NSString).length)
            try check(found?.emoji == emoji, "shortcut \(input)")
        }
        for input in ["http://example.test/:)", "abc:)", "file:)", "(:)", ":)word", "plain text"] {
            try check(EmojiShortcuts.replacement(in: input, caret: (input as NSString).length) == nil, "embedded token converted")
        }
        try check(EmojiShortcuts.replacement(in: ":)word", caret: 2) == nil, "mid-word caret converted")
        try check(EmojiShortcuts.replacement(in: ":)", caret: 99) == nil, "invalid caret accepted")
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 400,height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ComposerNSTextView(frame: NSRect(x: 0,y: 0,width: 400,height: 100))
        view.isRichText = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        window.contentView = view
        window.makeFirstResponder(view)
        func reset(_ text: String) { view.string = text; view.setSelectedRange(NSRange(location: (text as NSString).length,length: 0)); view.undoManager?.removeAllActions() }
        func type(_ text: String) { for character in text { view.insertText(String(character), replacementRange: view.selectedRange()) } }
        reset("Hello "); type(":)")
        try check(view.string == "Hello 🙂", "typed shortcut did not convert")
        try check(view.selectedRange().location == (view.string as NSString).length, "caret lost after emoji")
        view.undoManager?.undo()
        try check(view.string == "Hello :)", "undo did not restore emoticon: \(view.string.debugDescription), grouping \(view.undoManager?.groupingLevel ?? -1)")
        view.undoManager?.redo()
        try check(view.string == "Hello 🙂", "redo failed")
        reset("😀 "); type("<3")
        try check(view.string == "😀 ❤️", "Unicode prefix damaged")
        reset("before remove after"); view.setSelectedRange(NSRange(location: 7,length: 6)); type(":)")
        try check(view.string == "before 🙂 after", "selected text replacement damaged suffix")
        reset(""); view.insertText("Pasted :) text", replacementRange: view.selectedRange())
        try check(view.string == "Pasted :) text", "paste rewritten")
        reset(""); view.emojiShortcutsEnabled = false; type(":)")
        try check(view.string == ":)", "disabled shortcut converted")
        view.emojiShortcutsEnabled = true
        reset(""); view.setMarkedText(":", selectedRange: NSRange(location: 1,length: 0), replacementRange: NSRange(location: 0,length: 0))
        view.insertText(":)", replacementRange: view.markedRange())
        try check(view.string == ":)", "IME composition rewritten")

        var sent = 0
        view.submit = { sent += 1 }
        func press(_ modifiers: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            view.keyDown(with: event)
        }
        reset("Hello"); press([])
        try check(sent == 1 && view.string == "Hello", "Return did not send: \(view.string.debugDescription)")
        press(.shift)
        try check(sent == 1 && view.string == "Hello\n", "Shift-Return did not add a plain newline: \(view.string.debugDescription)")
        press(.option)
        try check(sent == 1 && view.string == "Hello\n\n", "Option-Return did not add a newline")
        reset(""); view.setMarkedText("か", selectedRange: NSRange(location: 1,length: 0), replacementRange: NSRange(location: 0,length: 0))
        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        try check(sent == 1, "Return sent while an input method was composing")
        view.unmarkText()
        view.submit = nil
        reset("Hello"); press([])
        try check(view.string == "Hello\n", "Return without a send action should add a line")
    }
}
