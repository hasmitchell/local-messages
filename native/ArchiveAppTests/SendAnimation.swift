#if UI_SNAPSHOTS
import AppKit
import SQLite3
import SwiftUI

// Runs the real send presentation against a synthetic SQLite writer. The
// command sink is replaced before enabling Send; nothing reaches a phone.
@MainActor enum SendAnimationRunner {
    private struct Failure: Error { let message: String }
    private nonisolated static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            try check(Date() < deadline, "send state timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func run(model: ArchiveModel, output: URL) async {
        var report: [String: Any] = [:]
        do {
            guard let directory = model.directory, directory.lastPathComponent == "review-fixture", !model.canSync else { throw Failure(message: "requires a synthetic archive") }
            let writer = try Writer(directory: directory)
            var commands: [SendCommand] = []
            model.simulatedSend = { commands.append($0) }
            model.canSync = true; model.syncEnabled = true; model.syncState = .connected
            let originalIDs = model.messages.map(\.id)
            model.editDraft("See you there! 🙂\nI'll bring the coffee.")
            try await Task.sleep(for: .milliseconds(100))
            capture("send-before", output: output)
            let oldPulse = model.sendPulse
            model.sendDraft()
            let pulse = model.sendPulse
            try check(pulse != oldPulse && !model.loadingMessages && model.messages.map(\.id) == originalIDs, "send cleared or reloaded the conversation")
            try check(model.displayedOutbox.count == 1 && model.draftIsInTimeline, "pending bubble was not immediate")
            model.sendDraft()
            await model.finishDraftSaves()
            try check(commands.count == 1, "repeat click submitted twice")
            let command = commands[0]
            let durable = try await DraftRepository().load(directory: directory)
            try check(durable["alex"]?.submissionID == command.id && durable["alex"]?.body == command.body, "visual clear lost durable draft")
            try await Task.sleep(for: .milliseconds(400))
            capture("send-pending", output: output)
            try writer.acknowledge(command)
            try await wait { model.draft.submissionID == nil }
            try check(model.displayedOutbox.count == 1 && model.sendPulse == pulse && !model.loadingMessages, "acknowledgement duplicated or replayed the bubble")
            try writer.confirm(command, remote: "animation-first")
            try await wait { model.messages.contains { $0.id == "animation-first" } }
            try check(model.messageSubmissions["animation-first"] == command.id && model.displayedOutbox.isEmpty, "confirmation did not preserve identity or remove the placeholder")
            try check(model.sendPulse == pulse && model.scrollRequest?.animated == false && !model.loadingMessages, "confirmation replayed the send animation")
            try await Task.sleep(for: .milliseconds(350))
            capture("send-confirmed", output: output)
            try check(model.timelineAtBottom, "confirmed send left the jump-to-bottom button visible")
            model.jumpToLatest()
            try await Task.sleep(for: .milliseconds(450))
            try check(model.timelineAtBottom, "jumping while already at the bottom showed the button")
            model.userScrolledTimeline()
            model.scrollRequest = ArchiveModel.ScrollRequest(messageID: originalIDs[10], atBottom: false)
            try await wait { !model.timelineAtBottom }
            model.jumpToLatest()
            try await wait { model.timelineAtBottom }
            try await Task.sleep(for: .milliseconds(450))
            try check(model.timelineAtBottom && !model.hasLater, "jump-to-bottom did not stay cleared")
            report["jump_button_clears_after_send_and_jump"] = true
            report["single_entrance_and_stable_confirmation"] = true
            report["durable_draft_and_duplicate_click_guard"] = true

            // Two identical texts still have distinct bubble identities.
            model.editDraft(command.body); model.sendDraft(); await model.finishDraftSaves()
            try check(commands.count == 2 && commands[1].id != command.id, "identical messages reused an attempt")
            try writer.acknowledge(commands[1]); try writer.confirm(commands[1], remote: "animation-second")
            try await wait { model.messages.contains { $0.id == "animation-second" } }
            try check(model.messageSubmissions["animation-first"] != model.messageSubmissions["animation-second"] && model.displayedOutbox.isEmpty, "identical sends merged")
            report["identical_messages_remain_separate"] = true

            model.simulatedSend = { _ in throw Failure(message: "synthetic disconnected worker") }
            model.editDraft("Keep this unsent draft"); model.sendDraft(); await model.finishDraftSaves()
            try check(model.displayedOutbox.count == 1 && model.displayedOutbox[0].state == "unknown" && model.draft.body == "Keep this unsent draft", "uncertain send lost its visible or saved text")
            model.checkSubmission()
            try await wait { model.draft.submissionID == nil }
            try check(!model.draftIsInTimeline && model.draft.body == "Keep this unsent draft" && model.displayedOutbox.isEmpty, "unsubmitted draft did not recover")
            report["uncertain_send_recovery"] = true

            model.editDraft("")
            model.select("alex", messageID: "alex-0000")
            try await wait { !model.loadingMessages }
            try check(model.hasLater, "old history setup failed")
            model.simulatedSend = { commands.append($0) }
            model.editDraft("Sending while reading older messages"); model.sendDraft()
            try check(!model.loadingMessages && !model.messages.isEmpty, "send from history blanked the timeline")
            await model.finishDraftSaves()
            try await wait { !model.hasLater }
            try check(model.messages.contains { $0.id == "animation-second" }, "send did not reveal latest history")
            report["send_from_older_history"] = true
            // Let the send finish scrolling, then move the real viewport. A
            // synthetic false flag alone can be overwritten by layout callbacks.
            try await wait { model.timelineAtBottom }
            try await Task.sleep(for: .milliseconds(450))
            model.userScrolledTimeline()
            model.scrollRequest = ArchiveModel.ScrollRequest(messageID: model.messages[10].id, atBottom: false)
            try await wait { !model.timelineAtBottom }
            try writer.acknowledge(commands.last!); try writer.confirm(commands.last!, remote: "animation-after-scroll")
            try await wait { model.hasLater }
            try check(!model.messages.contains { $0.id == "animation-after-scroll" }, "send-following overrode manual scrolling")
            report["manual_scroll_takes_over"] = true
            model.jumpToLatest()
            try await wait { !model.loadingMessages && !model.hasLater && model.messages.contains { $0.id == "animation-after-scroll" } }
            try await Task.sleep(for: .milliseconds(450))
            try check(model.timelineAtBottom, "jumping from an older page left the button visible")
            model.select("maya")
            try await wait { !model.loadingMessages }
            try await Task.sleep(for: .milliseconds(450))
            try check(model.timelineAtBottom, "short conversation showed a jump-to-bottom button")
            report["jump_from_history_and_short_thread"] = true
            report["passed"] = true
        } catch {
            report["passed"] = false; report["error"] = String(describing: error)
            report["at_bottom"] = model.timelineAtBottom; report["has_later"] = model.hasLater
            report["read_error"] = model.error ?? "none"
        }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("send-animation.json"))
    }
    private static func capture(_ name: String, output: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
              let image = SnapshotRunner.render(window), let png = image.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: output.appendingPathComponent(name + ".png"))
    }
    private final class Writer {
        let db: OpaquePointer
        init(directory: URL) throws {
            var opened: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("archive.db").path, &opened, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let opened else { throw Failure(message: "cannot open synthetic writer") }
            db = opened
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key='kind'", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0), String(cString: value) == "ui_fixture" else { throw Failure(message: "refusing to write a real archive") }
        }
        deinit { sqlite3_close(db) }
        func execute(_ sql: String, _ values: [String] = []) throws {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "synthetic SQL preparation failed")
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
            try check(sqlite3_step(statement) == SQLITE_DONE, "synthetic SQL write failed")
        }
        func acknowledge(_ command: SendCommand) throws {
            let now = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
            try execute("INSERT INTO outbox VALUES(?,?,?,'accepted','',?,?,'')", [command.id, command.conversationID, command.body, now, now])
            let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
            try execute("INSERT INTO outbox_commands VALUES(?,?)", [command.id, json])
        }
        func confirm(_ command: SendCommand, remote: String) throws {
            let stamp = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
            let payload: [String: Any] = ["id": remote, "conversation_id": command.conversationID, "body": command.body, "sender": "You", "outgoing": true, "transport": "RCS", "status": "OUTGOING_COMPLETE"]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("INSERT INTO messages VALUES(?,?,?,?,?,?)", [remote, command.conversationID, stamp, command.body, "You", json])
                try execute("UPDATE outbox SET state='confirmed',remote_id=? WHERE id=?", [remote, command.id])
                try execute("UPDATE conversations SET last_message=? WHERE id=?", [stamp, command.conversationID])
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }
}
#endif
