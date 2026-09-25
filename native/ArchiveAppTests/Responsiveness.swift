#if UI_SNAPSHOTS
import AppKit
import SwiftUI

/// Counts redraws of the large views, so checks can assert that unrelated
/// changes (typing, sync status) leave them alone.
@MainActor enum RenderCount {
    static var counts: [String: Int] = [:]
    static func bump(_ view: String) { counts[view, default: 0] += 1 }
    static func during(_ work: () async -> Void) async -> [String: Int] {
        let before = counts
        await work()
        var changed: [String: Int] = [:]
        for (view, count) in counts where count != before[view] { changed[view] = count - (before[view] ?? 0) }
        return changed
    }
}

@MainActor enum ResponsivenessRunner {
    private static func editor(_ view: NSView) -> ComposerNSTextView? {
        if let text = view as? ComposerNSTextView { return text }
        return view.subviews.lazy.compactMap { editor($0) }.first
    }
    private static var input: ComposerNSTextView? {
        NSApp.windows.filter(\.isVisible).compactMap { $0.contentView.flatMap(editor) }.first
    }
    static func run(model: ArchiveModel, output: URL) async {
        guard let input else { exit(2) }
        input.window?.makeFirstResponder(input)
        var typing: [Double] = [], turn: [Double] = []
        let typingRenders = await RenderCount.during {
            for letter in "This is a synthetic draft to measure typing responsiveness on the Mac." {
                let start = Date()
                input.insertText(String(letter), replacementRange: input.selectedRange())
                typing.append(Date().timeIntervalSince(start) * 1000)
                let next = Date()
                try? await Task.sleep(for: .milliseconds(12))
                turn.append(max(0, Date().timeIntervalSince(next) * 1000 - 12))
            }
        }
        var selection: [Double] = []
        for id in ["dad", "alex", "maya", "alex"] {
            let start = Date()
            model.select(id)
            selection.append(Date().timeIntervalSince(start) * 1000)
            guard model.selectedID == id, model.loadingMessages, model.messages.isEmpty else { exit(3) }
            while model.loadingMessages { try? await Task.sleep(for: .milliseconds(10)) }
        }
        try? await Task.sleep(for: .seconds(1))
        let (idleCPU, idleRenders) = await idle(model: model, seconds: 5)
        let status = await changeCost(count: 5) { model.syncStateChanged($0 % 2 == 0 ? .photosPending : .connected) }
        func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))] }
        let metrics: [String: Any] = ["typing_ms_p95": p95(typing), "typing_ms_max": typing.max() ?? 0, "main_actor_delay_ms_p95": p95(turn), "redraws_while_typing": typingRenders.filter { $0.key != "composer" }.values.reduce(0, +), "selection_call_ms_max": selection.max() ?? 0,
                                      "idle_cpu_percent": idleCPU, "idle_redraws_5s": idleRenders.values.reduce(0, +),
                                      "status_change_redraws": status.renders, "status_change_cpu_ms": status.medianMS]
        try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("performance.json"))
    }

    /// With nothing changing, the app should use almost no CPU and redraw nothing.
    static func idle(model: ArchiveModel, seconds: Int) async -> (cpuPercent: Double, renders: [String: Int]) {
        var cpu = 0.0
        let renders = await RenderCount.during {
            let start = cpuSeconds()
            try? await Task.sleep(for: .seconds(seconds))
            cpu = (cpuSeconds() - start) / Double(seconds) * 100
        }
        return (cpu, renders)
    }
    /// Median CPU (ms) spent after one model change, and which large views redrew.
    static func changeCost(count: Int, settle: Int = 700, _ change: (Int) -> Void) async -> (medianMS: Double, renders: [String: Int]) {
        var costs: [Double] = []
        let renders = await RenderCount.during {
            for index in 0..<count {
                try? await Task.sleep(for: .milliseconds(700))
                let start = cpuSeconds()
                change(index)
                // Long enough for the one-second archive poll to pick up a write.
                try? await Task.sleep(for: .milliseconds(settle))
                costs.append((cpuSeconds() - start) * 1000)
            }
        }
        return (costs.sorted()[costs.count / 2], renders.mapValues { $0 / count })
    }
    /// The longest the main thread went without running a 4 ms timer while
    /// `work` ran: roughly the worst dropped-frame hitch a user would see.
    static func longestStall(_ work: () async -> Void) async -> Double {
        final class Flag { var running = true }
        var longest = 0.0
        let flag = Flag()
        let probe = Task { @MainActor in
            var last = Date()
            while flag.running {
                try? await Task.sleep(for: .milliseconds(4))
                let now = Date()
                longest = max(longest, now.timeIntervalSince(last) * 1000 - 4)
                last = now
            }
        }
        await work()
        flag.running = false
        await probe.value
        return longest
    }
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private struct Failure: Error { let message: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private static func loaded(_ model: ArchiveModel) async throws {
        let start = Date()
        while model.loading || model.loadingMessages {
            try check(Date().timeIntervalSince(start) < 8, "archive loading timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(model.error == nil, "archive load failed")
        try await Task.sleep(for: .milliseconds(60))
    }
    static func validate(model: ArchiveModel, output: URL) async {
        var report: [String: Any] = [:]
        do {
            guard let first = model.directory, !model.canSync, first.lastPathComponent == "review-fixture" else { throw Failure(message: "requires synthetic review fixture") }
            try check(model.timelineAtBottom, "initial conversation did not settle at the bottom")
            model.select("dad"); model.select("maya"); model.select("alex")
            try check(model.selectedID == "alex" && model.messages.isEmpty && model.loadingMessages, "selection did not update immediately")
            try await loaded(model)
            try check(!model.messages.isEmpty && model.messages.allSatisfy { $0.conversationID == "alex" }, "stale conversation result won")
            report["rapid_selection"] = true
            try await Task.sleep(for: .milliseconds(400))
            try check(model.timelineAtBottom, "switched conversation did not settle at the bottom")
            report["latest_at_bottom"] = model.timelineAtBottom

            guard let input else { throw Failure(message: "composer not found") }
            input.window?.makeFirstResponder(input)
            for character in "Draft A :)" { input.insertText(String(character), replacementRange: input.selectedRange()) }
            try check(model.draft.body == "Draft A 🙂", "native typing did not update current draft")
            model.select("dad")
            try await loaded(model)
            try check(Self.input?.string == "" && Self.input?.undoManager?.canUndo == false, "previous conversation text or undo leaked")
            model.editDraft("Draft B")
            model.select("alex")
            try check(model.draft.body == "Draft A 🙂", "switch lost current in-memory draft")
            await model.finishDraftSaves()
            let saved = try await DraftRepository().load(directory: first)
            try check(saved["alex"]?.body == "Draft A 🙂" && saved["dad"]?.body == "Draft B", "quit flush lost a draft")
            report["composer_and_quit_flush"] = true

            model.editDraft("Latest text before reopen")
            model.open(first)
            try await loaded(model)
            try check(model.draft.body == "Latest text before reopen", "reopen beat pending save")
            report["reopen_during_debounce"] = true

            let second = first.deletingLastPathComponent().appendingPathComponent("review-second-" + UUID().uuidString)
            try FileManager.default.copyItem(at: first, to: second)
            defer { try? FileManager.default.removeItem(at: second) }
            model.editDraft("First archive")
            model.open(second)
            try await loaded(model)
            model.editDraft("Second archive")
            model.open(first)
            try await loaded(model)
            try check(model.draft.body == "First archive", "draft crossed archive boundary")
            await model.finishDraftSaves()
            let secondDrafts = try await DraftRepository().load(directory: second)
            try check(secondDrafts["alex"]?.body == "Second archive", "inactive archive draft did not save")
            report["separate_archive_drafts"] = true

            model.select("alex", messageID: "alex-0000")
            try await loaded(model)
            try check(model.messages.contains { $0.id == "alex-0000" } && model.hasLater && !model.timelineAtBottom, "old message navigation failed")
            model.showLatest()
            try await loaded(model)
            try check(!model.hasLater && model.messages.last?.id == "alex-0244", "return to latest failed")
            report["history_navigation"] = true
            report["passed"] = true
        } catch { report["passed"] = false; report["error"] = String(describing: error) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("composer-checks.json"))
    }
}
#endif
