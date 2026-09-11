import Foundation

@main struct RelinkTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() {
            if Date() > deadline { throw Failure(message: "worker did not stop") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func main() async {
        do { try await run(); print("Reconnect checks passed: status parsing, worker exit, cancellation, failure and retry.") }
        catch { print("Reconnect check failed: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        try check(RelinkStatus.parse(#"{"state":"waiting_for_phone","emoji":"🐢"}"#)?.emoji == "🐢", "emoji status")
        for line in [#"{"state":"unexpected"}"#, #"{"state":"complete","emoji":"🐢"}"#, #"{"state":"stopping"}"#, String(repeating: "x", count: 512), #"{"state":"waiting_for_phone","emoji":"account@example.test"}"#] {
            try check(RelinkStatus.parse(line) == nil, "invalid status accepted")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relink-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func script(_ body: String) throws -> URL {
            let url = directory.appendingPathComponent(UUID().uuidString)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        for (body, expected) in [
            ("echo '{\"state\":\"signing_in\"}'\necho '{\"state\":\"complete\"}'\n", RelinkState.complete),
            ("echo '{\"state\":\"wrong_phone\"}'\nexit 1\n", .wrongPhone),
            ("echo '{\"state\":\"complete\"}'\nexit 1\n", .failed),
            ("exit 0\n", .failed)
        ] {
            let controller = RelinkController(workerURL: try script(body))
            var prepared = false, finished = 0
            controller.start(directory: directory, prepare: { prepared = true }, finished: { finished += 1 })
            try await waitUntil { !controller.busy }
            try check(prepared && finished == 1 && controller.state == expected, "process completion validation")
            controller.reset()
            try check(controller.state == .ready, "terminal reset")
        }
        let newPairing = RelinkController(workerURL: try script("[ \"$1\" = pair ] && [ \"$6\" = --existing-archive ] || exit 1\necho '{\"state\":\"complete\"}'\n"))
        newPairing.start(directory: directory, addingAccount: true, existingArchives: [directory.appendingPathComponent("existing")], prepare: {}, finished: {})
        try await waitUntil { !newPairing.busy }
        try check(newPairing.state == .complete, "new account operation or duplicate-check arguments missing")
        let controller = RelinkController(workerURL: try script("echo '{\"state\":\"waiting_for_phone\",\"emoji\":\"🐢\"}'\nread ignored\nexit 1\n"))
        var finished = 0
        controller.start(directory: directory, prepare: {}, finished: { finished += 1 })
        try await waitUntil { controller.state == .waitingForPhone }
        try check(controller.busy && controller.emoji == "🐢", "phone prompt")
        controller.cancel()
        try await waitUntil { !controller.busy }
        try check(controller.state == .cancelled && finished == 1, "cancellation finishes once after worker exit")
        controller.start(directory: directory, prepare: { try await Task.sleep(for: .seconds(3)) }, finished: { finished += 1 })
        controller.cancel()
        try await waitUntil { !controller.busy }
        try check(controller.state == .cancelled && finished == 2, "cancel before worker launch")
        controller.start(directory: directory, prepare: { throw Failure(message: "sync still owns archive") }, finished: { finished += 1 })
        try await waitUntil { !controller.busy }
        try check(controller.state == .archiveBusy && finished == 3, "failed pause does not launch pairing")
    }
}
