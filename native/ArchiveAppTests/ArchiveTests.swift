import Foundation

@main struct ArchiveTests {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Native archive check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let reader = try ArchiveDatabase(directory: directory)
        let overview = try await reader.overview()
        if CommandLine.arguments.contains("--inspect") {
            print("Archive opens read-only: \(overview.conversations.count) conversations, \(overview.messageCount) messages, \(overview.imageCount) images.")
            let usage = try await ArchiveStorageReader().measure(directory: directory)
            print("Archive bytes on disk: \(usage.total); database \(usage.database); media \(usage.media); drafts \(usage.drafts); working files \(usage.workingFiles); other \(usage.other); incomplete \(usage.incomplete).")
            return
        }
        try check(overview.messageCount == 280, "fixture message count")
        try check(await reader.rejectsWritesForTesting(), "database denies writes and disabling query-only mode")
        try check(overview.conversations.count == 9, "conversation inventory")
        let person = overview.conversations.first { $0.id == "alex" }!
        try check(person.numbers == "+61 400 000 001" && person.ownParticipantIDs == ["self"], "phone details exclude own number")
        let library = try await reader.library(conversation: "alex", limit: 300)
        try check(library.files.count == 1 && library.links.count == 3 && !library.hasMore, "thread photo and link library excludes email links")
        try check(library.links.allSatisfy { $0.message.conversationID == "alex" && $0.url.scheme == "https" }, "library stays in selected conversation")
        let partialLibrary = try await reader.library(conversation: "alex", limit: 100)
        try check(partialLibrary.hasMore && partialLibrary.links.isEmpty, "library scans older messages on request")
        let latest = try await reader.latest(conversation: "alex")
        try check(latest.messages.count == 100 && latest.hasEarlier && !latest.hasLater, "latest page boundaries")
        var all = latest.messages
        while let first = all.first {
            let more = try await reader.earlier(than: first)
            if more.isEmpty { break }
            all = more + all
        }
        try check(all.count == 245 && Set(all.map(\.id)).count == 245, "paging has no gaps or duplicates")
        try check(zip(all, all.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }, "chronological order")
        let matches = try await reader.search("booking", conversation: nil)
        try check(matches.total == 2, "full-text search")
        let old = try await reader.around(messageID: "alex-0000", conversation: "alex")
        try check(old.messages.first?.id == "alex-0000" && old.hasLater && !old.hasEarlier, "search opens old message in context")
        let next = try await reader.later(than: old.messages.last!)
        try check(next.first?.id == "alex-0051", "later page after search")
        let scoped = try await reader.search("booking", conversation: "dad")
        try check(scoped.total == 0, "conversation search scope")
        let accented = try await reader.search("cafe", conversation: "alex")
        try check(accented.total == 1, "diacritic-insensitive search")
        _ = try await reader.search("\" OR * NEAR(foo)", conversation: nil)
        let empty = try await reader.latest(conversation: "empty")
        try check(empty.messages.isEmpty && !empty.hasEarlier && !empty.hasLater, "empty conversation")
        let image = latest.messages.flatMap(\.attachments).first!
        try check(image.localURL(in: directory) != nil, "local photo resolves")
        let unsafe = try JSONDecoder().decode(AttachmentRecord.self, from: Data(#"{"id":"x","name":"x","mime":"image/png","size":1,"path":"../archive.db","state":"downloaded_original"}"#.utf8))
        try check(unsafe.localURL(in: directory) == nil, "attachment path traversal rejected")
        let symlink = directory.appendingPathComponent("media/escape")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: directory.appendingPathComponent("archive.db"))
        let linked = try JSONDecoder().decode(AttachmentRecord.self, from: Data(#"{"id":"x","name":"x","mime":"image/png","size":1,"path":"media/escape","state":"downloaded_original"}"#.utf8))
        try check(linked.localURL(in: directory) == nil, "attachment symlink escape rejected")
        try FileManager.default.removeItem(at: symlink)
        let cards = try await reader.latest(conversation: "dad").messages.flatMap(\.attachments)
        try check(cards.count == 1 && cards[0].isContact && !cards[0].isImage, "vCard detection handles phone MIME casing")
        let cardURL = cards[0].localURL(in: directory)!
        let contacts = try await SharedContactReader.shared.load(url: cardURL)
        try check(contacts.count == 2 && contacts[0].name == "Zoë Rivera", "multiple Unicode contacts")
        let fields = contacts[0].fields.map(\.value)
        try check(fields.contains("+61 400 000 001") && fields.contains("+61 2 5550 0100") && fields.contains("zoe@example.invalid"), "phone numbers and email are preserved")
        try check(fields.contains("https://example.invalid/a-long-folded-path") && fields.contains(where: { $0.contains("10 Example Street") }), "folded vCard lines and postal address")
        try check(contacts[1].name.contains("Example;Jr."), "vCard escaped punctuation")
        let fallbackCard = AttachmentRecord(id: "fallback", name: "Card.VCF", mime: "application/octet-stream", size: 1, path: nil, state: "pending")
        try check(fallbackCard.isContact, "filename fallback for unknown vCard MIME")
        let parameterCard = AttachmentRecord(id: "parameter", name: "", mime: "Text/VCard; charset=UTF-8", size: 1, path: nil, state: "pending")
        try check(parameterCard.isContact && parameterCard.displayName == "Shared contact", "MIME parameters and nameless card")
        let invalidCard = directory.appendingPathComponent("media/invalid.vcf")
        try Data("not a contact card".utf8).write(to: invalidCard)
        do {
            _ = try await SharedContactReader.shared.load(url: invalidCard)
            try check(false, "malformed vCard rejected")
        } catch ContactPreviewFailure.invalid { }
        try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: invalidCard)
        do {
            _ = try await SharedContactReader.shared.load(url: invalidCard)
            try check(false, "oversized vCard rejected")
        } catch ContactPreviewFailure.tooLarge { }
        try FileManager.default.removeItem(at: invalidCard)
        try check(try await reader.isLive() == false, "synthetic archive cannot enable Google sync")
        let version = try await reader.dataVersion()
        let update = Process()
        update.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        update.arguments = ["native/ArchiveAppTests/append_update.py", directory.path]
        update.standardOutput = FileHandle.nullDevice
        try update.run()
        update.waitUntilExit()
        try check(update.terminationStatus == 0, "synthetic update writer")
        try check(try await reader.dataVersion() != version, "detect another connection's commit")
        let refreshed = try await reader.refresh(old.messages, conversation: "alex")
        try check(refreshed.messages.first?.id == old.messages.first?.id && refreshed.messages.last?.id == old.messages.last?.id, "background refresh preserves range")
        try check(refreshed.messages.first?.body.contains("BOOKING-BETA") == true && refreshed.messages.first?.reactions.count == 1, "background edit and reaction refresh")
        let tail = try await reader.refresh(latest.messages, conversation: "alex")
        try check(tail.hasLater && tail.messages.last?.id == latest.messages.last?.id, "new arrival offers navigation without moving history")
        let following = try await reader.refresh(latest.messages, conversation: "alex", followingLatest: true)
        try check(!following.hasLater && following.messages.last?.id != latest.messages.last?.id, "new replies appear automatically at the latest edge")
        try check(TimelinePolicy.followsLatest(atBottom: true, hasLater: false, highlighting: false) && !TimelinePolicy.followsLatest(atBottom: false, hasLater: false, highlighting: false) && !TimelinePolicy.followsLatest(atBottom: true, hasLater: false, highlighting: true), "following latest preserves scrolled and highlighted history")
        let refreshedSearch = try await reader.search("booking", conversation: nil)
        try check(refreshedSearch.total == 3, "search sees newly synced text")
        let pending = try await reader.outbox(conversation: "alex")
        try check(pending.count == 2 && pending.contains(where: { $0.state == "unknown" }), "persistent ambiguous and failed sends")
        try check(try await reader.submissionExists("fixture-unconfirmed"), "submission acknowledgement survives restart")
        let arrivals = try await reader.arrivals(after: 0)
        try check(arrivals.count == 1, "arrival journal reader")
        var incoming = arrivals[0].message
        let now = Date()
        incoming.timestamp = Int64(now.timeIntervalSince1970 * 1_000_000)
        try check(NotificationPolicy.shouldNotify(incoming, started: now.addingTimeInterval(-10), now: now, activeConversation: nil), "fresh incoming notification")
        try check(!NotificationPolicy.shouldNotify(incoming, started: now.addingTimeInterval(-10), now: now, activeConversation: "alex"), "active conversation suppression")
        try check(!NotificationPolicy.shouldNotify(incoming, started: now.addingTimeInterval(1), now: now, activeConversation: nil), "historical import suppression")
        try check(!NotificationPolicy.shouldNotify(incoming, started: now.addingTimeInterval(-1000), now: now.addingTimeInterval(301), activeConversation: nil), "stale catch-up suppression")
        try check(!NotificationPolicy.shouldNotify(latest.messages.last!, started: .distantPast, now: latest.messages.last!.date, activeConversation: nil), "outgoing suppression")
        try check(!SendCommand.validBody("  \n ") && !SendCommand.validBody(String(repeating: "a", count: 4001)) && SendCommand.validBody("Hello 😀\nSecond line"), "composer validation")
        let repository = DraftRepository()
        let original = DraftRecord(body: "Saved Unicode 😀\nsecond line", submissionID: "pending-attempt")
        try await repository.save(["alex": original], directory: directory, revision: 2)
        try await repository.save(["alex": DraftRecord(body: "stale")], directory: directory, revision: 1)
        let reloadedDraft = try await DraftRepository().load(directory: directory)
        try check(reloadedDraft["alex"] == original, "durable draft and attempt ID; stale saves ignored")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("drafts/drafts.json").path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private draft file")
        let files = try await AttachmentStager().stage(urls: [cardURL], directory: directory, existing: [])
        try check(files.count == 1 && files[0].size > 0 && files[0].sha256.count == 64, "attachment copy is bounded and fingerprinted")
        let stagedURL = directory.appendingPathComponent("drafts/attachments/" + files[0].id)
        try check(try Data(contentsOf: stagedURL) == Data(contentsOf: cardURL), "staging retains exact original bytes")
        var cachedImage = directory.appendingPathComponent("media/coast.png")
        let originalImage = try Data(contentsOf: cachedImage)
        cachedImage.setTemporaryResourceValue(0, forKey: .fileSizeKey)
        cachedImage.setTemporaryResourceValue(false, forKey: .isRegularFileKey)
        let imageFiles = try await AttachmentStager().stage(urls: [cachedImage], directory: directory, existing: files)
        let imageCopy = directory.appendingPathComponent("drafts/attachments/" + imageFiles[0].id)
        try check(try Data(contentsOf: imageCopy) == originalImage, "photo staging ignores stale picker metadata")
        let oversizedImage = directory.appendingPathComponent("media/oversized.png")
        try Data(repeating: 0, count: Int(DraftAttachment.byteLimit) + 1).write(to: oversizedImage)
        do {
            _ = try await AttachmentStager().stage(urls: [oversizedImage], directory: directory, existing: [])
            try check(false, "oversized photo rejected before staging")
        } catch AttachmentFailure.limit { }
        try FileManager.default.removeItem(at: oversizedImage)
        let attachmentDraft = DraftRecord(body: "A contact", files: files)
        try await repository.save(["alex": attachmentDraft], directory: directory, revision: 3)
        try check(try await DraftRepository().load(directory: directory)["alex"] == attachmentDraft, "attachment drafts survive restart")
        let command = SendCommand(id: UUID().uuidString.lowercased(), conversationID: "alex", body: "", files: files)
        let encoded = try JSONEncoder().encode(command)
        try check(try JSONDecoder().decode(SendCommand.self, from: encoded) == command, "private attachment command round trip")
        let settingsStore = SettingsRepository()
        let storageRoot = directory.appendingPathComponent("storage-check", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot.appendingPathComponent("media"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageRoot.appendingPathComponent("drafts"), withIntermediateDirectories: true)
        for name in ["archive.db", "archive.db-wal", "media/photo.png", "drafts/attachment", ".settings-test"] {
            try Data(repeating: 65, count: 8192).write(to: storageRoot.appendingPathComponent(name))
        }
        let storageReader = ArchiveStorageReader()
        let usage = try await storageReader.measure(directory: storageRoot)
        try check(usage.database > 0 && usage.media > 0 && usage.drafts > 0 && usage.workingFiles > 0 && usage.other > 0 && !usage.incomplete, "storage includes database, media, drafts, working and hidden files")
        try FileManager.default.createSymbolicLink(at: storageRoot.appendingPathComponent("media/outside"), withDestinationURL: directory)
        let withLink = try await storageReader.measure(directory: storageRoot)
        try check(withLink.total == usage.total && !withLink.incomplete, "storage does not follow symlinks outside the archive or into cycles")
        try Data(repeating: 66, count: 8192).write(to: storageRoot.appendingPathComponent("media/new-photo.png"))
        let increased = try await storageReader.measure(directory: storageRoot)
        try check(increased.media > usage.media && increased.database == usage.database && increased.total - usage.total == increased.media - usage.media, "storage refresh picks up new downloads in the media category")
        try FileManager.default.removeItem(at: storageRoot)
        let temporaryStorage = FileManager.default.temporaryDirectory.appendingPathComponent("archive-size-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryStorage, withIntermediateDirectories: true)
        try Data(repeating: 67, count: 8192).write(to: temporaryStorage.appendingPathComponent("archive.db"))
        let temporaryUsage = try await storageReader.measure(directory: temporaryStorage)
        try check(temporaryUsage.database > 0 && temporaryUsage.other == 0 && !temporaryUsage.incomplete, "storage categories handle macOS temporary-directory path aliases")
        try FileManager.default.removeItem(at: temporaryStorage)
        try check(try await settingsStore.load(directory: directory).retentionDays == 0, "automatic cleanup defaults off")
        let settings = ArchiveSettings(historySince: "2020-01-01", retentionDays: 90)
        try await settingsStore.save(settings, directory: directory)
        try check(try await settingsStore.load(directory: directory) == settings, "history and cleanup settings persist")
        try await settingsStore.save(.initial, directory: directory)
        // Restore a clean fixture draft for manual UI checks.
        try await repository.save([:], directory: directory, revision: 4)
        print("Native archive checks passed: paging, search, old-message context, scope, attachment paths, shared contacts, live refresh, outbox states, draft persistence and notification filtering.")
    }
    static func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw NSError(domain: "ArchiveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }
}
