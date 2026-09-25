import Foundation

// Only a standalone emoticon immediately before the caret is eligible. This
// never scans old messages, pasted text, URLs or the rest of the draft.
enum EmojiShortcuts {
    struct Replacement: Equatable { let range: NSRange; let emoji: String }
    private static let shortcuts: [(String, String)] = [
        (":-)", "🙂"), (":)", "🙂"), (":-(", "🙁"), (":(", "🙁"),
        (";-)", "😉"), (";)", "😉"), (":-D", "😃"), (":D", "😃"),
        (":-P", "😛"), (":P", "😛"), (":-p", "😛"), (":p", "😛"),
        (":-O", "😮"), (":O", "😮"), (":-o", "😮"), (":o", "😮"),
        (":'(", "😢"), ("<3", "❤️")
    ]
    static func replacement(in text: String, caret: Int) -> Replacement? {
        let value = text as NSString
        guard caret > 0, caret <= value.length else { return nil }
        func whitespace(at index: Int) -> Bool {
            guard let scalar = UnicodeScalar(value.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        guard caret == value.length || whitespace(at: caret) else { return nil }
        for (shortcut, emoji) in shortcuts {
            let length = (shortcut as NSString).length, start = caret - (shortcut as NSString).length
            guard start >= 0, start == 0 || whitespace(at: start - 1) else { continue }
            let range = NSRange(location: start, length: length)
            if value.substring(with: range) == shortcut { return Replacement(range: range, emoji: emoji) }
        }
        return nil
    }
}
