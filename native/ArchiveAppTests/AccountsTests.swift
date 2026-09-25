import Foundation

@main struct AccountsTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() { if Date() > deadline { throw Failure(message: "worker did not transition") }; try await Task.sleep(for: .milliseconds(40)) }
    }
    @MainActor static func main() async {
        do { try await run(); print("Account checks passed: catalog migration, isolated paths, pending recovery, launch selection, drafts/settings separation and one active sync worker.") }
        catch { print("Account check failed: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original archive")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let sentinel = Data("original messages".utf8)
        try sentinel.write(to: original.appendingPathComponent("archive.db"))
        let catalog = root.appendingPathComponent("catalog")
        var store = try AccountStore(root: catalog)
        let first = try store.register(directory: original)
        try check(first.directory.path == original.standardizedFileURL.path && first.name == "Personal", "legacy archive path changed")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let duplicate = try store.register(directory: alias)
        try check(duplicate.id == first.id && duplicate.directory.path == original.standardizedFileURL.path && store.profiles.count == 1, "alias changed Keychain path or duplicated account")
        let pending = try store.createPending(name: "Work")
        try check(pending.directory.path != original.path && !pending.setupComplete, "new account reused existing archive")
        store = try AccountStore(root: catalog)
        try check(store.profiles.count == 2 && !store.profiles[1].setupComplete, "cancelled setup was not retained")
        try store.complete(pending.id)
        try store.rename(first.id, to: "My Pixel")
        store = try AccountStore(root: catalog)
        try check(store.profiles[0].name == "My Pixel" && store.profiles[1].setupComplete, "rename or completion not persisted")
        try check(try Data(contentsOf: original.appendingPathComponent("archive.db")) == sentinel, "registration touched archive")
        try check(AccountLaunch.directory(arguments: ["app","--default-archive",original.path], savedPath: pending.path, profiles: store.profiles)?.path == pending.directory.path, "normal launch lost last account")
        try check(AccountLaunch.directory(arguments: ["app","--archive",original.path], savedPath: pending.path, profiles: store.profiles)?.path == original.path, "explicit archive ignored")
        try check(AccountLaunch.directory(arguments: ["app","--default-archive",original.path], savedPath: nil, profiles: [])?.path == original.path, "first launch lost existing CLI archive")
        // Both accounts deliberately use the same conversation ID.
        let drafts = DraftRepository(), settings = SettingsRepository()
        try await drafts.save(["same-chat": DraftRecord(body: "personal draft")], directory: original, revision: 1)
        try await drafts.save(["same-chat": DraftRecord(body: "work draft")], directory: pending.directory, revision: 2)
        try check(try await drafts.load(directory: original)["same-chat"]?.body == "personal draft", "personal draft leaked")
        try check(try await drafts.load(directory: pending.directory)["same-chat"]?.body == "work draft", "work draft leaked")
        let personalSettings = ArchiveSettings(historySince: "2021-09-11", retentionDays: 0)
        try await settings.save(personalSettings, directory: original)
        try check(try await settings.load(directory: pending.directory) == .initial, "new account inherited another account's cleanup")
        try check(try await settings.load(directory: original) == personalSettings, "original history settings changed")
        // A synthetic executable logs each lifetime; no Google helper is used.
        let worker = root.appendingPathComponent("worker")
        let events = root.appendingPathComponent("events")
        let script = """
        #!/bin/sh
        archive="$3"
        printf '%s\\n' "start:$archive" >> '\(events.path)'
        trap 'printf "%s\\n" "stop:$archive" >> "\(events.path)"' EXIT
        trap 'exit 0' TERM
        echo '{"state":"connected","time":"2026-09-11T04:00:00Z","connection":"synthetic"}'
        read ignored
        exit 0
        """
        try Data(script.utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        var state: SyncState = .local
        let sync = SyncController(workerURL: worker) { state = $0 }
        sync.configure(directory: original, enabled: true)
        try await waitUntil { state == .connected }
        sync.configure(directory: pending.directory, enabled: true)
        try await waitUntil { state == .connected }
        sync.configure(directory: original, enabled: true)
        try await waitUntil { state == .connected }
        sync.configure(directory: nil, enabled: false)
        try await waitUntil { sync.isStopped }
        let lines = try String(contentsOf: events, encoding: .utf8).split(separator: "\n").map(String.init)
        try check(lines == ["start:" + original.path, "stop:" + original.path, "start:" + pending.path, "stop:" + pending.path, "start:" + original.path, "stop:" + original.path], "workers overlapped or account switch used wrong directory")
        // Invalid catalogs must fail closed rather than discarding saved entries.
        try Data("corrupt".utf8).write(to: catalog.appendingPathComponent("accounts.json"))
        do { _ = try AccountStore(root: catalog); throw Failure(message: "corrupt catalog accepted") }
        catch is DecodingError { }
    }
}
