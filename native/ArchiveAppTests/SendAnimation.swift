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
            try check(model.displayedOutbox.count == 1 && model.draftIsInTimeline && model.arrivingRows == ["outbox-" + pulse.uuidString.lowercased()], "pending bubble was not immediate")
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
            // The follow scroll eases (0.8.13); the bubble's entrance must not replay.
            try check(model.sendPulse == pulse && !model.loadingMessages && model.arrivingRows.isSubset(of: ["outbox-" + command.id]), "confirmation replayed the send animation")
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

            // A reaction shows on its message at once; the phone's answer settles
            // it without any caption, and only a failure says anything.
            guard let target = model.messages.first(where: { $0.id == "alex-0242" }) else { throw Failure(message: "reaction target missing") }
            model.react(target, emoji: "👍")
            try check(commands.count == 3 && commands[2].kind == "react" && commands[2].emoji == "👍" && commands[2].messageID == target.id, "reaction was not handed to the worker")
            try check(model.pendingReactions[target.id]?.emoji == "👍" && !model.canReact(target), "reaction did not show at once")
            try await Task.sleep(for: .milliseconds(450))
            capture("react-pending", output: output)
            try writer.reaction(commands[2], state: "sending")
            try await Task.sleep(for: .milliseconds(1200))
            try check(model.pendingReactions[target.id] != nil && model.outbox.isEmpty, "an in-flight reaction became a timeline row")
            try writer.reaction(commands[2], state: "applied")
            try writer.setReactions(target.id, [["emoji": "👍", "participants": ["self"]]])
            try await wait { model.pendingReactions.isEmpty }
            try check(model.messages.first { $0.id == target.id }?.reactions.map(\.emoji) == ["👍"] && model.reactionNotice == nil, "the phone's copy did not take over quietly")
            guard let liked = model.messages.first(where: { $0.id == target.id }) else { throw Failure(message: "reaction target vanished") }
            try check(model.canReact(liked), "settled reaction left the message locked")
            model.react(liked, emoji: "😂")
            try check(commands.count == 4 && commands[3].emoji == "😂", "switching reaction was not sent")
            try writer.reaction(commands[3], state: "failed", reason: "offline")
            try await wait { model.pendingReactions.isEmpty }
            try check(model.reactionNotice?.contains("isn’t connected") == true && model.canReact(liked), "failed reaction was not reported")
            model.editDraft("Typing does not hide it"); model.editDraft("")
            try check(model.reactionNotice != nil, "typing hid the reaction failure")
            model.react(liked, emoji: "👍")
            try check(commands.count == 5 && commands[4].emoji == "", "choosing the current reaction did not remove it")
            try writer.reaction(commands[4], state: "applied")
            try writer.setReactions(target.id, [])
            try await wait { model.pendingReactions.isEmpty }
            try check(model.messages.first { $0.id == target.id }?.reactions.isEmpty == true, "removal did not settle")
            report["optimistic_reactions"] = true

            // A reply from the other side eases in like a send; the marker clears afterwards.
            try writer.arrive("animation-reply", conversation: "alex", body: "On my way!")
            try await wait { model.messages.contains { $0.id == "animation-reply" } }
            try check(model.arrivingRows == ["animation-reply"], "an arriving reply did not enter")
            try await Task.sleep(for: .milliseconds(450))
            capture("arrival", output: output)
            try await wait { model.arrivingRows.isEmpty }
            report["arrivals_enter"] = true

            // A failed attempt can be dismissed: it leaves at once and the worker is told.
            let failed = SendCommand(id: UUID().uuidString.lowercased(), conversationID: "alex", body: "This one failed")
            try writer.acknowledge(failed); try writer.reaction(failed, state: "failed", reason: "offline")
            try await wait { model.displayedOutbox.contains { $0.id == failed.id && $0.state == "failed" } }
            guard let failedRow = model.displayedOutbox.first(where: { $0.id == failed.id }) else { throw Failure(message: "failed row missing") }
            try check(model.canDismiss(failedRow), "a failed attempt could not be dismissed")
            let sentBefore = commands.count
            model.dismissSend(failedRow)
            try check(!model.displayedOutbox.contains { $0.id == failed.id } && commands.count == sentBefore + 1 && commands.last?.kind == "dismiss" && commands.last?.id == failed.id, "dismiss did not hide the attempt or tell the worker")
            try await Task.sleep(for: .milliseconds(1500))
            try check(!model.displayedOutbox.contains { $0.id == failed.id }, "a dismissed attempt came back before the worker recorded it")
            report["failed_send_dismisses"] = true

            model.simulatedSend = { _ in throw Failure(message: "synthetic disconnected worker") }
            model.editDraft("Keep this unsent draft"); model.sendDraft(); await model.finishDraftSaves()
            try check(model.displayedOutbox.count == 1 && model.displayedOutbox[0].state == "unknown" && model.draft.body == "Keep this unsent draft", "uncertain send lost its visible or saved text")
            model.checkSubmission()
            try await wait { model.draft.submissionID == nil }
            try check(!model.draftIsInTimeline && model.draft.body == "Keep this unsent draft" && model.displayedOutbox.isEmpty, "unsubmitted draft did not recover")
            report["uncertain_send_recovery"] = true

            // With no worker to take it, the message goes straight back to the composer.
            model.simulatedSend = { _ in throw SyncController.NotConnected() }
            model.sendDraft(); await model.finishDraftSaves()
            try check(model.draft.submissionID == nil && model.draft.body == "Keep this unsent draft" && model.displayedOutbox.isEmpty && model.composerError?.contains("isn’t connected") == true, "an undeliverable send kept the composer locked")
            report["undeliverable_send_returns_to_composer"] = true

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
            report["paging"] = model.paging; report["highlighted"] = model.highlightedID ?? "none"
            report["outbox"] = model.displayedOutbox.map { "\($0.id.prefix(8)):\($0.state)" }
            report["following"] = model.followingOwnSend; report["composer_error"] = model.composerError ?? "none"
            capture("send-failure", output: output)
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
        func reaction(_ command: SendCommand, state: String, reason: String = "") throws {
            let now = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
            try execute("INSERT INTO outbox VALUES(?,?,'',?,?,?,?,'') ON CONFLICT(id) DO UPDATE SET state=excluded.state,reason=excluded.reason,updated=excluded.updated", [command.id, command.conversationID, state, reason, now, now])
            let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
            try execute("INSERT OR IGNORE INTO outbox_commands VALUES(?,?)", [command.id, json])
        }
        func setReactions(_ messageID: String, _ reactions: [[String: Any]]) throws {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: reactions), as: UTF8.self)
            try execute("UPDATE messages SET payload=CAST(json_set(CAST(payload AS TEXT),'$.reactions',json(?)) AS BLOB) WHERE id=?", [json, messageID])
        }
        func arrive(_ id: String, conversation: String, body: String) throws {
            let stamp = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
            let payload: [String: Any] = ["id": id, "conversation_id": conversation, "body": body, "sender": "Alex Morgan", "outgoing": false, "transport": "RCS", "status": "INCOMING_COMPLETE"]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            try execute("INSERT INTO messages VALUES(?,?,?,?,?,?)", [id, conversation, stamp, body, "Alex Morgan", json])
            try execute("UPDATE conversations SET last_message=? WHERE id=?", [stamp, conversation])
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
