import AppKit

// Dictates a synthesized recording into a composer text view through the
// on-device model path (needs macOS 26 and the model; downloads it if missing).
@main struct SpeechTests {
    @MainActor static func main() async {
        guard #available(macOS 26, *) else { print("Speech checks skipped: needs macOS 26."); return }
        guard ComposerEditorActions.onDeviceAvailable else { print("Speech checks skipped: the on-device model is unavailable on this Mac."); return }
        let actions = ComposerEditorActions()
        let textView = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        actions.textView = textView
        textView.string = "Note:"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        var volatileUpdates = 0, sawMarked = false
        textView.textActivity = { volatileUpdates += 1; if textView.hasMarkedText() { sawMarked = true } }
        var statuses: [String] = []
        let watch = Task { @MainActor in
            var last: String?
            while !Task.isCancelled {
                if let status = actions.voiceStatus, status != last { statuses.append(status); last = status; print("status:", status) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        do {
            let started = Date()
            try await actions.dictateForTesting(file: URL(fileURLWithPath: CommandLine.arguments[1]))
            watch.cancel()
            let text = textView.string
            print("result (\(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(volatileUpdates) in-progress updates):", text.debugDescription)
            let lower = text.lowercased()
            guard text.hasPrefix("Note: "), !text.hasPrefix("Note:  "), !textView.hasMarkedText(),
                  (lower.contains("nine") || lower.contains("9")), lower.contains("coffee"), sawMarked, !actions.dictating else {
                print("Speech check failed"); exit(1)
            }
            print("Speech checks passed: model ready, in-progress words shown as marked text, settled words committed with spacing.")
        } catch {
            watch.cancel()
            print("Speech check failed:", error); exit(1)
        }
    }
}
