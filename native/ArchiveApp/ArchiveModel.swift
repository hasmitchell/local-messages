import AppKit
import CryptoKit
import SwiftUI

enum ConversationFilter: String, CaseIterable, Identifiable {
    case inbox = "Inbox", archived = "Archived"
    var id: String { rawValue }
}

// Observation tracks each property separately: a view redraws only when a value
// it read changes. Bookkeeping that views never read is ignored, so writes to it
// (including caches filled during a redraw) invalidate nothing.
@MainActor @Observable
final class ArchiveModel {
    var overview: ArchiveOverview?
    var directory: URL?
    var selectedID: String?
    var messages: [MessageRecord] = []
    var query = ""
    var filter: ConversationFilter = .inbox
    var searchResults: [MessageRecord] = []
    var searchTotal = 0
    var searching = false
    var loading = false
    var loadingMessages = false
    var paging = false
    var hasEarlier = false
    var hasLater = false
    var error: String?
    var searchError: String?
    var highlightedID: String?
    var scrollRequest: ScrollRequest?
    var previewURL: URL?
    var focusSearch = UUID()
    var timelineAtBottom = true
    var showingThreadSearch = false
    var threadQuery = ""
    var threadResults: [MessageRecord] = []
    var threadTotal = 0
    var threadSearching = false
    var threadError: String?
    var showingDetails = false
    var windowIsKey = true
    var showingNewMessage = false
    var pendingStart: PendingStart?
    var startError: String?
    struct PendingStart: Equatable { let id, number: String; let started: Date }
    @ObservationIgnored private var markedRead: [String: String] = [:]
    var canStartConversation: Bool { canSync && syncEnabled && syncState.canSend && !pairingBusy && pendingStart == nil }
    private(set) var seenRevision = 0
    @ObservationIgnored private var seenStore: SeenStore?
    var library = ConversationLibrary()
    var libraryLoading = false
    var libraryError: String?
    var settings = ArchiveSettings.initial
    var savingSettings = false
    var settingsNotice: String?
    var settingsError: String?
    var stagingAttachments = false
    var pendingReactions: [String: String] = [:]
    @ObservationIgnored private let settingsRepository = SettingsRepository()
    @ObservationIgnored private let attachmentStager = AttachmentStager()
    @ObservationIgnored private var threadSearchTask: Task<Void, Never>?
    @ObservationIgnored private var threadSearchGeneration = UUID()
    @ObservationIgnored private var libraryGeneration = UUID()
    @ObservationIgnored private var libraryLimit = 300

    var syncState: SyncState = .local
    var canSync = false
    var syncEnabled = !UserDefaults.standard.bool(forKey: "syncPaused")
    @ObservationIgnored private lazy var syncController: SyncController = {
        let controller = SyncController { [weak self] state in self?.syncStateChanged(state) }
        controller.onTyping = { [weak self] digest, active in self?.typingChanged(digest: digest, active: active) }
        return controller
    }()
    func syncStateChanged(_ state: SyncState) {
        // The worker repeats its status every pass. Publishing an unchanged
        // value would re-render every view that reads the model.
        guard state != syncState else { return }
        let wasReady = syncState.canSend
        syncState = state
        if state.canSend && !wasReady { sendPresence() }
    }
    /// Conversations where the other side is typing, by the worker's digest of the conversation id.
    private(set) var typingDigests: [String: Date] = [:]
    @ObservationIgnored private var typingDigestCache: [String: String] = [:]
    @ObservationIgnored private var lastTypingSent: (conversation: String, at: Date)?
    func typingChanged(digest: String, active: Bool) {
        if active { typingDigests[digest] = Date() } else { typingDigests.removeValue(forKey: digest) }
    }
    private func typingDigest(_ conversationID: String) -> String {
        if let cached = typingDigestCache[conversationID] { return cached }
        let digest = String(SHA256.hash(data: Data(conversationID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        typingDigestCache[conversationID] = digest
        return digest
    }
    /// True while the other side has typed within the last eight seconds.
    func isTyping(_ conversationID: String) -> Bool {
        guard let at = typingDigests[typingDigest(conversationID)] else { return false }
        return Date().timeIntervalSince(at) < 8
    }
    private func expireTyping() {
        let stale = typingDigests.filter { Date().timeIntervalSince($0.value) >= 8 }.map(\.key)
        for key in stale { typingDigests.removeValue(forKey: key) }
    }
    /// Lets the phone show that a reply is being written, at most once every four seconds.
    private func sendTypingIfNeeded(_ conversationID: String) {
        guard canSync, syncEnabled, syncState.canSend, !pairingBusy else { return }
        if let last = lastTypingSent, last.conversation == conversationID, Date().timeIntervalSince(last.at) < 4 { return }
        lastTypingSent = (conversationID, Date())
        try? syncController.send(SendCommand(kind: "typing", id: UUID().uuidString.lowercased(), conversationID: conversationID, body: ""))
    }
    /// The worker polls the phone less while the app is not in front; fresh messages still arrive through events.
    func sendPresence() {
        guard canSync, syncEnabled, syncState.canSend else { return }
        let state = NSApp.isActive ? "active" : "idle"
        try? syncController.send(SendCommand(kind: "presence", id: UUID().uuidString.lowercased(), conversationID: "", body: state))
    }
    let relinking = RelinkController()
    let addingAccount = RelinkController()
    var accounts: [AccountProfile] = []
    var showingAccounts = false
    var showingAccountSetup = false
    var accountError: String?
    var settingUpAccount: AccountProfile?
    @ObservationIgnored private var accountStore: AccountStore?
    private(set) var accountListAvailable = false
    var pairingBusy: Bool { relinking.busy || addingAccount.busy }
    var currentAccount: AccountProfile? { directory.flatMap { location in accounts.first { AccountStore.key($0.directory) == AccountStore.key(location) } } }
    var accountName: String { currentAccount?.name ?? (canSync ? "Current account" : "Local archive") }
    let draftState = ComposerDraftState()
    private(set) var draftPreviews: [String: DraftRecord] = [:]
    var drafts: [String: DraftRecord] {
        get { draftState.records }
        set {
            guard draftState.records != newValue else { return }
            draftState.records = newValue
            draftPreviews = newValue
            let sending = Set(newValue.compactMap { $0.value.submissionID == nil ? nil : $0.key })
            if sending != sendingDrafts { sendingDrafts = sending }
        }
    }
    /// Conversations whose draft is out for sending. Kept apart from the text so
    /// views that only need this are not redrawn on every keystroke.
    private(set) var sendingDrafts: Set<String> = []
    var draftSubmitted: Bool { selectedID.map(sendingDrafts.contains) ?? false }
    @ObservationIgnored private var draftSaveTasks: [String: Task<Void, Never>] = [:]
    var outbox: [OutboxRecord] = []
    private(set) var localOutbox: [String: OutboxRecord] = [:]
    private(set) var messageSubmissions: [String: String] = [:]
    private(set) var sendPulse = UUID()
    private var followingSubmission: String?
    var followingOwnSend: Bool { followingSubmission != nil }
    /// Counts wheel and trackpad scrolls; untracked, since no view draws it.
    @ObservationIgnored private(set) var manualScrolls = 0
    func userScrolledTimeline() { followingSubmission = nil; manualScrolls += 1 }
    #if UI_SNAPSHOTS
    @ObservationIgnored var simulatedSend: ((SendCommand) throws -> Void)?
    #endif
    var displayedOutbox: [OutboxRecord] {
        let savedIDs = Set(outbox.map(\.id)), confirmedIDs = Set(messageSubmissions.values)
        return (outbox + localOutbox.values.filter {
            $0.conversationID == selectedID && !savedIDs.contains($0.id) && !confirmedIDs.contains($0.id)
        }).sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }
    var draftIsInTimeline: Bool {
        guard let submission = draft.submissionID else { return false }
        return displayedOutbox.contains { $0.id == submission }
    }
    var composerError: String?
    @ObservationIgnored private let draftRepository = DraftRepository()
    @ObservationIgnored private var draftRevision = 0
    @ObservationIgnored private var arrivalSequence: Int64 = 0
    let notifications = MessageNotifications()
    @ObservationIgnored private var arrivalStart = Date()
    var draft: DraftRecord { selectedID.flatMap { drafts[$0] } ?? DraftRecord() }
    var canSendDraft: Bool { !pairingBusy && canSync && syncEnabled && syncState.canSend && selectedID != nil && draft.submissionID == nil && !stagingAttachments && draft.body.unicodeScalars.count <= 4000 && draft.body.utf8.count <= 16000 && (SendCommand.validBody(draft.body) || !draft.attachments.isEmpty) }
    var composerHint: String {
        if draft.submissionID != nil { return "Checking send status · Your text is saved" }
        if !canSync { return "Local draft · Sending requires a paired live archive" }
        if draft.body.unicodeScalars.count > 4000 || draft.body.utf8.count > 16000 { return "Use up to 4,000 characters" }
        if !syncEnabled || !syncState.canSend { return "Draft saved on this Mac · Connect your phone to send" }
        return "Uses your phone’s SMS/RCS settings · Shift-Return adds a new line"
    }
    func editDraft(_ body: String) {
        guard let id = selectedID, draft.submissionID == nil, let directory else { return }
        let previous = draft.body
        guard previous != body else { return }
        draftState.records[id] = DraftRecord(body: body, files: draft.files, replyTo: draft.replyTo)
        if composerError != nil { composerError = nil }
        persistDrafts(directory: directory, debounce: true)
        if body.count > previous.count { sendTypingIfNeeded(id) }
    }
    /// The message the draft will quote; nil when it is not in the loaded page.
    var replyTarget: MessageRecord? { draft.replyTo.flatMap { id in messages.first { $0.id == id } } }
    func setReplyTarget(_ message: MessageRecord?) {
        guard let id = selectedID, draft.submissionID == nil, let directory else { return }
        drafts[id] = DraftRecord(body: draft.body, files: draft.files, replyTo: message?.id)
        persistDrafts(directory: directory)
    }
    /// Sends text straight from a notification reply; the outbox still records the attempt.
    func quickReply(conversation: String, text: String) {
        guard canSync, syncEnabled, syncState.canSend, !pairingBusy, SendCommand.validBody(text),
              conversations.contains(where: { $0.id == conversation }) else {
            Task { await notifications.deliverFailure("Reply not sent", body: "The phone connection is not ready. Open Local Messages to send it.") }
            return
        }
        do { try syncController.send(SendCommand(id: UUID().uuidString.lowercased(), conversationID: conversation, body: text)) }
        catch { Task { await notifications.deliverFailure("Reply not sent", body: "The phone connection dropped. Open Local Messages to send it.") } }
    }
    /// Data dropped or pasted into the conversation becomes a staged file.
    func attachData(_ data: Data, suggestedName: String) {
        guard selectedID != nil, !data.isEmpty, data.count <= DraftAttachment.byteLimit else { composerError = AttachmentFailure.limit.localizedDescription; return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-messages-paste-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(suggestedName)
            try data.write(to: file, options: .atomic)
            attach([file])
            Task { try? await Task.sleep(for: .seconds(30)); try? FileManager.default.removeItem(at: folder) }
        } catch { composerError = AttachmentFailure.storage.localizedDescription }
    }
    func hasContacts() async -> Bool { (try? await database?.hasContacts()) ?? false }
    func searchContacts(_ query: String) async -> [ContactEntry] {
        guard let database else { return [] }
        return (try? await database.contacts(matching: query)) ?? []
    }
    func contactAvatarURL(_ entry: ContactEntry) -> URL? {
        guard let directory, let path = entry.avatarPath else { return nil }
        let record = ConversationRecord(id: entry.id, name: entry.name, folder: "INBOX", timestamp: 0, preview: "", messageCount: 0, participants: [ConversationParticipant(id: entry.id, name: entry.name, number: entry.number, isMe: false, avatarPath: path)])
        return record.avatarURL(in: directory)
    }
    private func persistDrafts(directory: URL, debounce: Bool = false) {
        draftRevision += 1
        let revision = draftRevision, snapshot = drafts, generation = archiveGeneration
        draftSaveTasks[directory.path]?.cancel()
        let repository = draftRepository
        draftSaveTasks[directory.path] = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                if let self, self.archiveGeneration == generation, self.draftPreviews != snapshot { self.draftPreviews = snapshot }
                try await repository.save(snapshot, directory: directory, revision: revision)
            } catch is CancellationError { }
            catch {
                if let self, self.archiveGeneration == generation { self.composerError = "The draft could not be saved on this Mac." }
            }
        }
    }
    // A normal quit waits for pending saves, including another account's draft
    // when the user has just switched accounts. Sending still saves immediately.
    func finishDraftSaves() async {
        for task in Array(draftSaveTasks.values) { await task.value }
    }
    func sendDraft() {
        guard canSendDraft, let id = selectedID, let directory else { return }
        let body = draft.body, submission = UUID().uuidString.lowercased(), generation = archiveGeneration
        let files = draft.files, replyTo = draft.replyTo
        let command = SendCommand(id: submission, conversationID: id, body: body, files: files, replyTo: replyTo)
        followingSubmission = submission
        let pending = OutboxRecord(id: submission, conversationID: id, body: body, state: "preparing", reason: "", remoteID: "", created: Int64(Date().timeIntervalSince1970 * 1_000_000), command: command)
        // Settle layout first. The bubble and scroll animate independently;
        // animating the entire stack makes its scroll target move underneath it.
        withTransaction(Transaction(animation: nil)) {
            drafts[id] = DraftRecord(body: body, submissionID: submission, files: files, replyTo: replyTo)
            localOutbox[submission] = pending
            sendPulse = UUID(uuidString: submission)!
            if !hasLater {
                highlightedID = nil
                scrollRequest = ScrollRequest(messageID: "timeline-bottom", atBottom: true, animated: true)
            }
        }
        revealLatestForSend(conversation: id)
        draftRevision += 1
        let revision = draftRevision, snapshot = drafts
        composerError = nil
        draftSaveTasks[directory.path]?.cancel()
        draftSaveTasks[directory.path] = Task {
            do {
                // Keep the text and attempt ID on disk until the worker has
                // committed an outbox row. A crash cannot silently lose a draft.
                try await draftRepository.save(snapshot, directory: directory, revision: revision)
                guard archiveGeneration == generation else { return }
                #if UI_SNAPSHOTS
                if let simulatedSend { try simulatedSend(command) }
                else { try syncController.send(command) }
                #else
                try syncController.send(command)
                #endif
            } catch {
                if archiveGeneration == generation {
                    if followingSubmission == submission { followingSubmission = nil }
                    localOutbox[submission] = OutboxRecord(id: submission, conversationID: id, body: body, state: "unknown", reason: "", remoteID: "", created: pending.created, command: command)
                    composerError = "Send status is not confirmed. Your text is saved; check the phone before sending again."
                }
            }
        }
    }
    private func revealLatestForSend(conversation: String) {
        guard hasLater, let reader = conversationDatabase else { return }
        let generation = messageGeneration
        Task {
            do {
                let window = try await reader.latest(conversation: conversation)
                guard messageGeneration == generation, selectedID == conversation else { return }
                // Keep the old history visible until the latest page is ready.
                apply(window)
                highlightedID = nil
                scrollRequest = ScrollRequest(messageID: "timeline-bottom", atBottom: true, animated: true)
            } catch { if messageGeneration == generation { self.error = readableError(error) } }
        }
    }
    func restoreDraft(_ message: OutboxRecord) {
        guard draft.body.isEmpty, draft.attachments.isEmpty, !message.isReaction, let directory, selectedID == message.conversationID else { return }
        drafts[message.conversationID] = DraftRecord(body: message.body, files: message.files)
        persistDrafts(directory: directory)
    }
    func checkSubmission() {
        guard let database, let directory else { return }
        let generation = archiveGeneration
        Task {
            do {
                try await acknowledgeDrafts(database, directory: directory, generation: generation)
                if archiveGeneration == generation, draft.submissionID != nil {
                    if syncController.isStopped, let id = selectedID {
                        if let submission = drafts[id]?.submissionID { localOutbox.removeValue(forKey: submission) }
                        drafts[id]?.submissionID = nil
                        persistDrafts(directory: directory)
                        composerError = "This attempt was not submitted. Your draft is ready to edit."
                    } else {
                        composerError = "Pause sync, then check again to recover an attempt that has no saved record. Your text is retained."
                    }
                }
            } catch { if archiveGeneration == generation { composerError = "The saved send status could not be read." } }
        }
    }
    private func acknowledgeDrafts(_ reader: ArchiveDatabase, directory: URL, generation: UUID) async throws {
        var changed = false
        for (id, saved) in drafts {
            guard let submission = saved.submissionID else { continue }
            let exists = try await reader.submissionExists(submission)
            guard archiveGeneration == generation else { return }
            if exists && drafts[id]?.submissionID == submission { drafts[id] = DraftRecord(); changed = true }
        }
        if changed { persistDrafts(directory: directory) }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var database: ArchiveDatabase?
    @ObservationIgnored private var conversationDatabase: ArchiveDatabase?
    @ObservationIgnored private var archiveGeneration = UUID()
    @ObservationIgnored private var messageGeneration = UUID()
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchLimit = 100

    struct ScrollRequest: Equatable {
        let token = UUID()
        let messageID: String
        let atBottom: Bool
        var animated = false
    }

    var conversations: [ConversationRecord] { overview?.conversations ?? [] }
    var selectedConversation: ConversationRecord? { conversations.first { $0.id == selectedID } }
    var visibleConversations: [ConversationRecord] {
        conversations.filter { conversation in
            switch filter {
            case .inbox: !conversation.isArchived
            case .archived: conversation.isArchived
            }
        }
    }
    var titleMatches: [ConversationRecord] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return conversations.filter { $0.title.localizedStandardContains(query) || $0.numbers.localizedStandardContains(query) }
    }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func conversationTitle(_ id: String) -> String { conversations.first { $0.id == id }?.title ?? "Conversation" }

    func start() {
        do { accountStore = try AccountStore(); accounts = accountStore!.profiles; accountListAvailable = true }
        catch { accountError = "The account list could not be read. Your archives are still on this Mac. Restore the list before adding accounts." }
        if let directory = AccountLaunch.directory(arguments: CommandLine.arguments, savedPath: UserDefaults.standard.string(forKey: "archiveDirectory"), profiles: accounts) {
            open(directory)
        }
    }

    func chooseArchive() {
        guard !pairingBusy, !savingSettings, !stagingAttachments else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Message Archive"
        panel.message = "Choose the archive folder containing archive.db and its media folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Archive"
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func toggleSync() {
        guard !pairingBusy else { return }
        syncEnabled.toggle()
        UserDefaults.standard.set(!syncEnabled, forKey: "syncPaused")
        syncController.configure(directory: canSync ? directory : nil, enabled: syncEnabled)
    }

    func retrySync() {
        guard !pairingBusy else { return }
        syncEnabled = true
        UserDefaults.standard.set(false, forKey: "syncPaused")
        syncController.configure(directory: canSync ? directory : nil, enabled: true)
    }

    func open(_ url: URL) {
        guard !pairingBusy, !savingSettings, !stagingAttachments else { return }
        // Resolve aliases to the registered path so Keychain lookup remains stable.
        let url = accountStore?.profile(at: url)?.directory ?? url.standardizedFileURL
        refreshTask?.cancel()
        syncController.configure(directory: nil, enabled: false)
        canSync = false
        pendingReactions = [:]; stagingAttachments = false
        drafts = [:]
        outbox = []
        localOutbox = [:]
        followingSubmission = nil
        messageSubmissions = [:]
        composerError = nil
        previewURL = nil; library = ConversationLibrary(); libraryLoading = false; libraryError = nil
        settingsNotice = nil; settingsError = nil
        notifications.configure(directory: nil, select: nil, reply: nil)
        let generation = UUID()
        archiveGeneration = generation
        messageGeneration = UUID()
        searchGeneration = UUID()
        messageTask?.cancel()
        searchTask?.cancel()
        loading = true
        error = nil
        overview = nil
        database = nil
        conversationDatabase = nil
        selectedID = nil
        messages = []
        searchResults = []
        query = ""
        threadQuery = ""; threadResults = []; showingThreadSearch = false; showingDetails = false
        threadSearchTask?.cancel(); libraryGeneration = UUID()
        directory = url.standardizedFileURL
        seenStore = SeenStore(directory: url)
        seenRevision += 1
        pendingStart = nil; startError = nil; showingNewMessage = false
        markedRead = [:]
        NSApp.dockTile.badgeLabel = nil
        let pendingDraftSave = draftSaveTasks[url.path]
        Task {
            do {
                let reader = try ArchiveDatabase(directory: url)
                let snapshot = try await reader.overview()
                let live = try await reader.isLive()
                // A quick switch away and back can beat the typing debounce.
                // Read only after that archive's latest draft is on disk.
                await pendingDraftSave?.value
                let savedDrafts = try await draftRepository.load(directory: url)
                let savedSettings = try await settingsRepository.load(directory: url)
                let cursor = try await reader.arrivalCursor()
                guard archiveGeneration == generation else { return }
                conversationDatabase = try ArchiveDatabase(directory: url)
                database = reader
                drafts = savedDrafts
                for (conversation, draft) in savedDrafts {
                    if let submission = draft.submissionID {
                        let command = SendCommand(id: submission, conversationID: conversation, body: draft.body, files: draft.files, replyTo: draft.replyTo)
                        localOutbox[submission] = OutboxRecord(id: submission, conversationID: conversation, body: draft.body, state: "unknown", reason: "", remoteID: "", created: 0, command: command)
                    }
                }
                settings = savedSettings
                arrivalSequence = cursor
                arrivalStart = Date()
                canSync = live
                if live, let store = accountStore {
                    do { try store.register(directory: url); accounts = store.profiles }
                    catch { accountError = "This archive opened, but it could not be saved to the account list." }
                }
                notifications.configure(directory: live ? url : nil, select: { [weak self] conversation, message in
                    guard self?.archiveGeneration == generation else { return }
                    self?.select(conversation, messageID: message)
                }, reply: { [weak self] conversation, text in
                    guard self?.archiveGeneration == generation else { return }
                    self?.quickReply(conversation: conversation, text: text)
                })
                syncController.configure(directory: live ? directory : nil, enabled: syncEnabled)
                observeChanges(reader, generation: generation)
                overview = snapshot
                loading = false
                updateBadge()
                UserDefaults.standard.set(url.path, forKey: "archiveDirectory")
                if let first = snapshot.conversations.first(where: { $0.messageCount > 0 }) ?? snapshot.conversations.first {
                    select(first.id)
                }
            } catch {
                guard archiveGeneration == generation else { return }
                self.error = readableError(error)
                loading = false
            }
        }
    }

    private func observeChanges(_ reader: ArchiveDatabase, generation: UUID) {
        refreshTask = Task { [weak self] in
            var version: Int64?
            while !Task.isCancelled {
                do {
                    let current = try await reader.dataVersion()
                    guard let self, self.archiveGeneration == generation else { return }
                    if let version, current != version {
                        // Retry later if a navigation operation currently owns
                        // the timeline; do not consume the database revision.
                        if self.loadingMessages || self.paging || self.loading {
                            try await Task.sleep(for: .seconds(1))
                            continue
                        }
                        try await self.refreshVisible(reader, generation: generation)
                    }
                    if self.canSync { try await self.checkArrivals(reader, generation: generation) }
                    self.checkStartTimeout()
                    self.expireTyping()
                    version = current
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch {
                    guard let self, self.archiveGeneration == generation else { return }
                    self.error = self.readableError(error)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func refreshVisible(_ reader: ArchiveDatabase, generation: UUID) async throws {
        let snapshot = try await reader.overview()
        guard archiveGeneration == generation else { return }
        if overview != snapshot { overview = snapshot; updateBadge() }
        try await checkPendingStart(reader, generation: generation)
        if let directory { try await acknowledgeDrafts(reader, directory: directory, generation: generation) }
        for (message, submission) in pendingReactions {
            if try await reader.submissionExists(submission) { pendingReactions.removeValue(forKey: message) }
        }
        guard archiveGeneration == generation else { return }
        let messageToken = messageGeneration
        if let id = selectedID, !loadingMessages, !paging {
            let following = followingSubmission != nil || TimelinePolicy.followsLatest(atBottom: timelineAtBottom, hasLater: hasLater, highlighting: highlightedID != nil)
            let snapshot = try await reader.timeline(conversation: id, visible: messages, followingLatest: following)
            let window = snapshot.window, pending = snapshot.outbox
            guard archiveGeneration == generation, messageGeneration == messageToken, !paging else { return }
            // Capture the position before adding rows changes the scrollable
            // height. Apply the rows and their scroll request in one UI update.
            let shouldFollow = following && (timelineAtBottom || followingSubmission != nil)
            let contentChanged = window.messages != messages || pending != outbox
            let oldIDs = Set(messages.map { messageSubmissions[$0.id].map { "outbox-" + $0 } ?? $0.id } + displayedOutbox.filter { !$0.isReaction }.map { "outbox-" + $0.id })
            let newIDs = Set(window.messages.map { window.submissions[$0.id].map { "outbox-" + $0 } ?? $0.id } + pending.filter { !$0.isReaction }.map { "outbox-" + $0.id })
            let inserted = !newIDs.subtracting(oldIDs).isEmpty
            // Confirmation keeps the existing row in place. Only new content
            // asks for an animated scroll; status changes never replay the send.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { apply(window); applyOutbox(pending) }
            if let followingSubmission, window.submissions.values.contains(followingSubmission) { self.followingSubmission = nil }
            if shouldFollow && contentChanged {
                scrollRequest = ScrollRequest(messageID: "timeline-bottom", atBottom: true, animated: inserted)
                if windowIsKey && NSApp.isActive { markVisibleAsSeen() }
            }
        }
        if showingThreadSearch && !threadQuery.isEmpty { scheduleThreadSearch() }
        if showingDetails { loadLibrary(reset: false) }
        if isSearching {
            let searchToken = searchGeneration
            let result = try await reader.search(query, conversation: nil, limit: searchLimit)
            guard archiveGeneration == generation, searchGeneration == searchToken else { return }
            searchResults = result.messages
            searchTotal = result.total
        }
    }

    private func checkArrivals(_ reader: ArchiveDatabase, generation: UUID) async throws {
        let arrivals = try await reader.arrivals(after: arrivalSequence)
        guard archiveGeneration == generation else { return }
        for arrival in arrivals {
            arrivalSequence = arrival.sequence
            let alreadyVisible = NSApp.isActive && windowIsKey && timelineAtBottom && !hasLater && messages.contains(where: { $0.id == arrival.message.id })
            if NotificationPolicy.shouldNotify(arrival.message, started: arrivalStart, now: Date(), activeConversation: alreadyVisible && !notifications.notifyWhileReading ? selectedID : nil) {
                await notifications.deliver(arrival.message, title: conversationTitle(arrival.message.conversationID))
                guard archiveGeneration == generation else { return }
            }
        }
    }

    func showLatest() {
        guard let id = selectedID else { return }
        select(id, force: true)
    }

    func jumpToLatest() {
        if hasLater { showLatest() }
        else {
            highlightedID = nil
            scrollRequest = ScrollRequest(messageID: "timeline-bottom", atBottom: true, animated: true)
        }
    }

    func reload() {
        guard let directory else { chooseArchive(); return }
        let previous = selectedID
        let generation = archiveGeneration
        guard let database else { open(directory); return }
        loading = true
        error = nil
        Task {
            do {
                let snapshot = try await database.overview()
                guard archiveGeneration == generation else { return }
                overview = snapshot
                loading = false
                updateBadge()
                if let id = previous ?? snapshot.conversations.first?.id { select(id, force: true) }
                scheduleSearch()
            } catch {
                guard archiveGeneration == generation else { return }
                self.error = readableError(error)
                loading = false
            }
        }
    }

    func select(_ id: String, messageID: String? = nil, force: Bool = false) {
        guard let database = conversationDatabase else { return }
        if id != selectedID || messageID != nil || force { followingSubmission = nil }
        if !force, selectedID == id {
            if let messageID, messages.contains(where: { $0.id == messageID }) {
                timelineAtBottom = false
                highlightedID = messageID
                scrollRequest = ScrollRequest(messageID: messageID, atBottom: false)
                return
            } else if messageID == nil { return }
        }
        if selectedID != id {
            threadQuery = ""; threadResults = []; threadTotal = 0
            threadSearchTask?.cancel(); threadSearchGeneration = UUID()
            libraryGeneration = UUID()
        }
        timelineAtBottom = messageID == nil
        selectedID = id
        highlightedID = messageID
        messageTask?.cancel()
        let generation = UUID()
        messageGeneration = generation
        messages = []
        messageSubmissions = [:]
        outbox = []
        composerError = nil
        hasEarlier = false
        hasLater = false
        paging = false
        loadingMessages = true
        error = nil
        messageTask = Task {
            do {
                // Let the selection, title and empty loading state reach a frame
                // before constructing the new message view hierarchy.
                try await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled, messageGeneration == generation else { return }
                let snapshot = try await database.timeline(conversation: id, messageID: messageID)
                guard !Task.isCancelled, messageGeneration == generation else { return }
                apply(snapshot.window)
                applyOutbox(snapshot.outbox)
                loadingMessages = false
                if messageID == nil { markVisibleAsSeen() }
                if let anchor = messageID ?? messages.last?.id {
                    scrollRequest = ScrollRequest(messageID: anchor, atBottom: messageID == nil)
                }
            } catch {
                guard !Task.isCancelled, messageGeneration == generation else { return }
                self.error = readableError(error)
                loadingMessages = false
            }
        }
    }

    func loadMore(earlier: Bool) {
        guard !paging, let database, let id = selectedID,
              let anchor = earlier ? messages.first : messages.last else { return }
        paging = true
        followingSubmission = nil
        if earlier { timelineAtBottom = false }
        let generation = messageGeneration
        Task {
            do {
                let extra = try await (earlier ? database.earlier(than: anchor) : database.later(than: anchor))
                guard messageGeneration == generation else { return }
                let joined = earlier ? extra + messages : messages + extra
                let window = try await database.window(joined, conversation: id)
                guard messageGeneration == generation else { return }
                apply(window)
                paging = false
                if earlier { scrollRequest = ScrollRequest(messageID: anchor.id, atBottom: false) }
            } catch {
                guard messageGeneration == generation else { return }
                self.error = readableError(error)
                paging = false
            }
        }
    }

    func scheduleSearch(more: Bool = false) {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        if more { searchLimit += 100 } else { searchLimit = 100; searchResults = []; searchTotal = 0 }
        searchError = nil
        guard isSearching, let database else { searching = false; highlightedID = nil; return }
        let text = query
        let scope: String? = nil
        let limit = searchLimit
        searching = true
        searchTask = Task {
            do {
                if !more { try await Task.sleep(for: .milliseconds(180)) }
                let result = try await database.search(text, conversation: scope, limit: limit)
                guard !Task.isCancelled, searchGeneration == generation else { return }
                searchResults = result.messages
                searchTotal = result.total
                searching = false
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                searchError = readableError(error)
                searching = false
            }
        }
    }

    func showReply(_ message: MessageRecord) {
        guard let reply = message.replyTo else { return }
        select(message.conversationID, messageID: reply)
    }

    func attach(_ urls: [URL]) {
        guard let directory, let id = selectedID, draft.submissionID == nil, !stagingAttachments else { return }
        let generation = archiveGeneration, existing = draft.attachments
        stagingAttachments = true
        composerError = nil
        Task {
            do {
                let files = try await attachmentStager.stage(urls: urls, directory: directory, existing: existing)
                guard generation == archiveGeneration else { return }
                var saved = drafts[id] ?? DraftRecord()
                saved.files = saved.attachments + files
                drafts[id] = saved
                persistDrafts(directory: directory)
            } catch { if generation == archiveGeneration { composerError = (error as? AttachmentFailure)?.localizedDescription ?? "These files could not be attached." } }
            if generation == archiveGeneration { stagingAttachments = false }
        }
    }
    func removeAttachment(_ id: String) {
        guard let directory, let conversation = selectedID, draft.submissionID == nil else { return }
        drafts[conversation]?.files?.removeAll { $0.id == id }
        persistDrafts(directory: directory)
    }
    func canReact(_ message: MessageRecord) -> Bool {
        !pairingBusy && !message.outgoing && canSync && syncEnabled && syncState.canSend && pendingReactions[message.id] == nil && !message.status.contains("DELETED") && !outbox.contains(where: { $0.isReaction && $0.command?.messageID == message.id && ["preparing", "sending", "unknown", "accepted"].contains($0.state) })
    }
    func ownReaction(_ message: MessageRecord) -> String? {
        let own = selectedConversation?.ownParticipantIDs ?? []
        return message.reactions.first { !own.isDisjoint(with: $0.participants ?? []) }?.emoji
    }
    func react(_ message: MessageRecord, emoji: String) {
        guard canReact(message) else { return }
        let submission = UUID().uuidString.lowercased()
        pendingReactions[message.id] = submission
        do {
            try syncController.send(SendCommand(kind: "react", id: submission, conversationID: message.conversationID, body: "", messageID: message.id, emoji: emoji))
            composerError = nil
        } catch { composerError = "Reaction status is unconfirmed. Check the phone before trying again." }
    }
    func scheduleThreadSearch(more: Bool = false) {
        threadSearchTask?.cancel()
        let token = UUID(); threadSearchGeneration = token
        guard let database, let id = selectedID, !threadQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { threadResults = []; threadTotal = 0; threadSearching = false; return }
        let query = threadQuery, limit = more ? threadResults.count + 100 : 100
        threadSearching = true; threadError = nil
        threadSearchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let result = try await database.search(query, conversation: id, limit: limit)
                guard !Task.isCancelled, threadSearchGeneration == token, selectedID == id else { return }
                threadResults = result.messages; threadTotal = result.total; threadSearching = false
            } catch is CancellationError { }
            catch { if threadSearchGeneration == token { threadError = "Conversation search could not be loaded."; threadSearching = false } }
        }
    }
    func loadLibrary(reset: Bool = true, more: Bool = false) {
        guard let database, let id = selectedID else { return }
        if reset { library = ConversationLibrary(); libraryLimit = 300 }
        if more { libraryLimit += 1000 }
        let token = UUID(); libraryGeneration = token
        libraryLoading = true; libraryError = nil
        Task {
            do {
                let result = try await database.library(conversation: id, limit: libraryLimit)
                guard libraryGeneration == token, selectedID == id else { return }
                library = result; libraryLoading = false
            } catch { if libraryGeneration == token { libraryError = "Shared items could not be loaded."; libraryLoading = false } }
        }
    }
    func saveSettings(_ value: ArchiveSettings) {
        guard let directory, value.valid, !savingSettings, !pairingBusy else { return }
        let generation = archiveGeneration
        savingSettings = true; settingsError = nil; settingsNotice = nil
        Task {
            do {
                try await settingsRepository.save(value, directory: directory)
                guard generation == archiveGeneration else { return }
                settings = value
                if canSync { syncController.configure(directory: directory, enabled: syncEnabled) }
                settingsNotice = syncEnabled && canSync ? "Saved. Sync will retrieve the selected history and apply optional local cleanup." : "Saved. History and cleanup will run when sync is enabled."
            } catch { if generation == archiveGeneration { settingsError = "Settings could not be saved." } }
            if generation == archiveGeneration { savingSettings = false }
        }
    }
    func cleanupPreview(_ value: ArchiveSettings) async -> Int? {
        guard let date = value.cleanupDate, let database else { return nil }
        return try? await database.cleanupPreview(before: date)
    }
    func switchAccount(_ profile: AccountProfile) {
        guard !pairingBusy, !savingSettings, !stagingAttachments else { return }
        if !profile.setupComplete {
            settingUpAccount = profile; addingAccount.reset(); showingAccountSetup = true; showingAccounts = true
        } else {
            settingUpAccount = nil
            open(profile.directory)
        }
    }
    func renameAccount(_ profile: AccountProfile, to name: String) {
        guard let store = accountStore else { return }
        do { try store.rename(profile.id, to: name); accounts = store.profiles; accountError = nil }
        catch { accountError = "The account name could not be saved. Use 1–60 characters." }
    }
    func prepareNewAccount() {
        guard !pairingBusy else { return }
        settingUpAccount = nil; addingAccount.reset(); showingAccountSetup = true; showingAccounts = true
    }
    func addAccount(named name: String) {
        guard let store = accountStore, !pairingBusy, !savingSettings, !stagingAttachments else { return }
        do {
            if settingUpAccount == nil { settingUpAccount = try store.createPending(name: name); accounts = store.profiles }
            guard let profile = settingUpAccount else { return }
            accountError = nil
            let generation = archiveGeneration, previous = directory
            let others = accounts.filter { $0.id != profile.id && ($0.setupComplete || FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("archive.db").path)) }.map(\.directory)
            addingAccount.start(directory: profile.directory, addingAccount: true, existingArchives: others, prepare: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.pauseForPairing()
            }, finished: { [weak self] in
                guard let self, self.archiveGeneration == generation else { return }
                if self.addingAccount.state == .complete {
                    do {
                        try store.complete(profile.id); self.accounts = store.profiles
                        self.open(profile.directory)
                    } catch {
                        self.accountError = "Pairing finished but the account list could not be updated. The setup entry and archive were kept; try again."
                        self.syncController.configure(directory: self.canSync ? previous : nil, enabled: self.syncEnabled)
                    }
                } else {
                    self.syncController.configure(directory: self.canSync ? previous : nil, enabled: self.syncEnabled)
                }
            })
        } catch { accountError = "A separate archive could not be created. Check available disk space and folder access." }
    }
    private func pauseForPairing() async throws {
        syncController.configure(directory: directory, enabled: false)
        let deadline = Date().addingTimeInterval(12)
        while !syncController.isStopped {
            if Date() >= deadline { throw CocoaError(.fileLocking) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func reconnectArchive() {
        guard canSync, let directory, !pairingBusy, !savingSettings else { return }
        let generation = archiveGeneration
        relinking.start(directory: directory, prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.pauseForPairing()
        }, finished: { [weak self] in
            guard let self, self.archiveGeneration == generation else { return }
            self.syncController.configure(directory: directory, enabled: self.syncEnabled)
        })
    }
    /// Asks the phone for the conversation belonging to a number; the result arrives through the outbox.
    func startConversation(with text: String) {
        guard canStartConversation else { return }
        guard let number = SendCommand.normalizedNumber(text) else {
            startError = "Enter a phone number, for example +61 400 000 000 or 0400 000 000."
            return
        }
        let id = UUID().uuidString.lowercased()
        startError = nil
        do {
            try syncController.send(SendCommand(kind: "start", id: id, conversationID: "", body: "", number: number))
            pendingStart = PendingStart(id: id, number: number, started: Date())
        } catch { startError = "The phone connection is not ready. Try again once sync shows Connected." }
    }
    private func checkPendingStart(_ reader: ArchiveDatabase, generation: UUID) async throws {
        guard let pending = pendingStart else { return }
        guard let status = try await reader.submission(pending.id), archiveGeneration == generation, pendingStart == pending else { return }
        switch status.state {
        case "resolved" where !status.remoteID.isEmpty:
            pendingStart = nil
            showingNewMessage = false
            if let conversation = conversations.first(where: { $0.id == status.remoteID }) { filter = conversation.isArchived ? .archived : .inbox }
            select(status.remoteID, force: true)
        case "failed":
            pendingStart = nil
            startError = status.reason == "offline" ? "The phone connection dropped before it answered. Try again once sync shows Connected."
                : "Your phone could not open a conversation with \(pending.number). Check the number and try again."
        default: break
        }
    }
    private func checkStartTimeout() {
        guard let pending = pendingStart, Date().timeIntervalSince(pending.started) > 60 else { return }
        pendingStart = nil
        startError = "No answer from the phone. Check that Google Messages is open on it, then try again."
    }
    func isUnread(_ conversation: ConversationRecord) -> Bool {
        _ = seenRevision
        return seenStore?.isUnread(conversation) ?? false
    }
    func avatarURL(_ conversation: ConversationRecord) -> URL? { overview?.avatarURLs[conversation.id] }
    /// The toolbar find field was closed (Esc or its cancel button): clear its results.
    func threadSearchDismissed() {
        threadSearchTask?.cancel(); threadQuery = ""; threadResults = []; threadTotal = 0; threadSearching = false; highlightedID = nil
    }
    var unreadCount: Int { conversations.filter { isUnread($0) }.count }
    func toggleDetails() { showingDetails.toggle() }
    func windowBecameKey() {
        guard highlightedID == nil, timelineAtBottom, !hasLater else { return }
        markVisibleAsSeen()
    }
    /// The open conversation is showing its newest local messages: clear its unread marker.
    private func markVisibleAsSeen() {
        guard let id = selectedID, let seenStore else { return }
        let timestamp = max(selectedConversation?.timestamp ?? 0, messages.last?.timestamp ?? 0)
        markReadOnPhoneIfNeeded()
        guard timestamp > 0, seenStore.markSeen(id, timestamp: timestamp) else { return }
        seenRevision += 1
        updateBadge()
    }
    /// Tells the phone the open conversation is read up to its newest message, once per message.
    private func markReadOnPhoneIfNeeded() {
        guard UserDefaults.standard.object(forKey: "markReadOnPhone") as? Bool ?? true,
              canSync, syncEnabled, syncState.canSend, !pairingBusy,
              let conversation = selectedConversation, conversation.unread,
              let latest = messages.last(where: { !$0.outgoing }) ?? messages.last,
              markedRead[conversation.id] != latest.id else { return }
        do {
            try syncController.send(SendCommand(kind: "mark_read", id: UUID().uuidString.lowercased(), conversationID: conversation.id, body: "", messageID: latest.id))
            markedRead[conversation.id] = latest.id
        } catch { /* Best effort: the phone keeps showing it unread until the next visit. */ }
    }
    private func updateBadge() {
        let count = canSync ? unreadCount : 0
        NSApp.dockTile.badgeLabel = count > 0 ? count.formatted() : nil
    }
    private func apply(_ window: MessageWindow) {
        if messageSubmissions != window.submissions { messageSubmissions = window.submissions }
        for submission in window.submissions.values where localOutbox[submission] != nil { localOutbox.removeValue(forKey: submission) }
        if messages != window.messages { messages = window.messages }
        if hasEarlier != window.hasEarlier { hasEarlier = window.hasEarlier }
        if hasLater != window.hasLater { hasLater = window.hasLater }
    }
    private func applyOutbox(_ pending: [OutboxRecord]) {
        if outbox != pending { outbox = pending }
        for record in pending where localOutbox[record.id] != nil { localOutbox.removeValue(forKey: record.id) }
        if pending.contains(where: { $0.id == followingSubmission && ["unknown", "failed"].contains($0.state) }) { followingSubmission = nil }
    }
    private func readableError(_ error: Error) -> String {
        // Do not put decoded message values, SQL or private paths into alerts.
        (error as? ArchiveFailure)?.localizedDescription ?? "The saved data could not be read. Try another archive or reload after the import finishes."
    }
}
