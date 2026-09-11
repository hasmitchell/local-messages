import AppKit
import SwiftUI

enum ConversationFilter: String, CaseIterable, Identifiable {
    case inbox = "Inbox", archived = "Archived"
    var id: String { rawValue }
}

@MainActor
final class ArchiveModel: ObservableObject {
    @Published var overview: ArchiveOverview?
    @Published var directory: URL?
    @Published var selectedID: String?
    @Published var messages: [MessageRecord] = []
    @Published var query = ""
    @Published var filter: ConversationFilter = .inbox
    @Published var searchResults: [MessageRecord] = []
    @Published var searchTotal = 0
    @Published var searching = false
    @Published var loading = false
    @Published var loadingMessages = false
    @Published var paging = false
    @Published var hasEarlier = false
    @Published var hasLater = false
    @Published var error: String?
    @Published var searchError: String?
    @Published var highlightedID: String?
    @Published var scrollRequest: ScrollRequest?
    @Published var previewURL: URL?
    @Published var focusSearch = UUID()
    @Published var timelineAtBottom = true
    @Published var showingThreadSearch = false
    @Published var threadQuery = ""
    @Published var threadResults: [MessageRecord] = []
    @Published var threadTotal = 0
    @Published var threadSearching = false
    @Published var threadError: String?
    @Published var showingDetails = false
    @Published var windowIsKey = true
    @Published private(set) var seenRevision = 0
    private var seenStore: SeenStore?
    @Published var library = ConversationLibrary()
    @Published var libraryLoading = false
    @Published var libraryError: String?
    @Published var settings = ArchiveSettings.initial
    @Published var savingSettings = false
    @Published var settingsNotice: String?
    @Published var settingsError: String?
    @Published var stagingAttachments = false
    @Published var pendingReactions: [String: String] = [:]
    private let settingsRepository = SettingsRepository()
    private let attachmentStager = AttachmentStager()
    private var threadSearchTask: Task<Void, Never>?
    private var threadSearchGeneration = UUID()
    private var libraryGeneration = UUID()
    private var libraryLimit = 300

    @Published var syncState: SyncState = .local
    @Published var canSync = false
    @Published var syncEnabled = !UserDefaults.standard.bool(forKey: "syncPaused")
    private lazy var syncController = SyncController { [weak self] state in self?.syncState = state }
    let relinking = RelinkController()
    let addingAccount = RelinkController()
    @Published var accounts: [AccountProfile] = []
    @Published var showingAccounts = false
    @Published var showingAccountSetup = false
    @Published var accountError: String?
    @Published var settingUpAccount: AccountProfile?
    private var accountStore: AccountStore?
    var accountListAvailable: Bool { accountStore != nil }
    var pairingBusy: Bool { relinking.busy || addingAccount.busy }
    var currentAccount: AccountProfile? { directory.flatMap { location in accounts.first { AccountStore.key($0.directory) == AccountStore.key(location) } } }
    var accountName: String { currentAccount?.name ?? (canSync ? "Current account" : "Local archive") }
    @Published var drafts: [String: DraftRecord] = [:]
    @Published var outbox: [OutboxRecord] = []
    @Published var composerError: String?
    private let draftRepository = DraftRepository()
    private var draftRevision = 0
    private var pendingScrollID: String?
    private var arrivalSequence: Int64 = 0
    let notifications = MessageNotifications()
    private var arrivalStart = Date()
    var draft: DraftRecord { selectedID.flatMap { drafts[$0] } ?? DraftRecord() }
    var canSendDraft: Bool { !pairingBusy && canSync && syncEnabled && syncState.canSend && selectedID != nil && draft.submissionID == nil && !stagingAttachments && draft.body.unicodeScalars.count <= 4000 && draft.body.utf8.count <= 16000 && (SendCommand.validBody(draft.body) || !draft.attachments.isEmpty) }
    var composerHint: String {
        if draft.submissionID != nil { return "Checking send status · Your text is saved" }
        if !canSync { return "Local draft · Sending requires a paired live archive" }
        if draft.body.unicodeScalars.count > 4000 || draft.body.utf8.count > 16000 { return "Use up to 4,000 characters" }
        if !syncEnabled || !syncState.canSend { return "Draft saved on this Mac · Connect your phone to send" }
        return "Uses your phone’s SMS/RCS settings · Return adds a new line"
    }
    func editDraft(_ body: String) {
        guard let id = selectedID, draft.submissionID == nil, let directory else { return }
        drafts[id] = DraftRecord(body: body, files: draft.files)
        composerError = nil
        persistDrafts(directory: directory)
    }
    private func persistDrafts(directory: URL) {
        draftRevision += 1
        let revision = draftRevision, snapshot = drafts, generation = archiveGeneration
        Task {
            do { try await draftRepository.save(snapshot, directory: directory, revision: revision) }
            catch { if archiveGeneration == generation { composerError = "The draft could not be saved on this Mac." } }
        }
    }
    func sendDraft() {
        guard canSendDraft, let id = selectedID, let directory else { return }
        let body = draft.body, submission = UUID().uuidString.lowercased(), generation = archiveGeneration
        let files = draft.files
        drafts[id] = DraftRecord(body: body, submissionID: submission, files: files)
        draftRevision += 1
        let revision = draftRevision, snapshot = drafts
        composerError = nil
        Task {
            do {
                // Keep the text and attempt ID on disk until the worker has
                // committed an outbox row. A crash cannot silently lose a draft.
                try await draftRepository.save(snapshot, directory: directory, revision: revision)
                guard archiveGeneration == generation else { return }
                try syncController.send(SendCommand(id: submission, conversationID: id, body: body, files: files))
                if selectedID == id {
                    showLatest()
                    pendingScrollID = submission
                    scrollRequest = ScrollRequest(messageID: "outbox-" + submission, atBottom: true)
                }
            } catch {
                if archiveGeneration == generation { composerError = "Send status is not confirmed. Your text is saved; check the phone before sending again." }
            }
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

    private var refreshTask: Task<Void, Never>?
    private var database: ArchiveDatabase?
    private var archiveGeneration = UUID()
    private var messageGeneration = UUID()
    private var searchGeneration = UUID()
    private var messageTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchLimit = 100

    struct ScrollRequest: Equatable {
        let token = UUID()
        let messageID: String
        let atBottom: Bool
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
        do { accountStore = try AccountStore(); accounts = accountStore!.profiles }
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
        composerError = nil
        previewURL = nil; library = ConversationLibrary(); libraryLoading = false; libraryError = nil
        settingsNotice = nil; settingsError = nil
        notifications.configure(directory: nil, select: nil)
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
        selectedID = nil
        messages = []
        searchResults = []
        query = ""
        threadQuery = ""; threadResults = []; showingThreadSearch = false; showingDetails = false
        threadSearchTask?.cancel(); libraryGeneration = UUID()
        directory = url.standardizedFileURL
        seenStore = SeenStore(directory: url)
        seenRevision += 1
        NSApp.dockTile.badgeLabel = nil
        Task {
            do {
                let reader = try ArchiveDatabase(directory: url)
                let snapshot = try await reader.overview()
                let live = try await reader.isLive()
                let savedDrafts = try await draftRepository.load(directory: url)
                let savedSettings = try await settingsRepository.load(directory: url)
                let cursor = try await reader.arrivalCursor()
                guard archiveGeneration == generation else { return }
                database = reader
                drafts = savedDrafts
                settings = savedSettings
                arrivalSequence = cursor
                arrivalStart = Date()
                canSync = live
                if live, let store = accountStore {
                    do { try store.register(directory: url); accounts = store.profiles }
                    catch { accountError = "This archive opened, but it could not be saved to the account list." }
                }
                notifications.configure(directory: live ? url : nil) { [weak self] conversation, message in
                    guard self?.archiveGeneration == generation else { return }
                    self?.select(conversation, messageID: message)
                }
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
        overview = snapshot
        updateBadge()
        if let directory { try await acknowledgeDrafts(reader, directory: directory, generation: generation) }
        for (message, submission) in pendingReactions {
            if try await reader.submissionExists(submission) { pendingReactions.removeValue(forKey: message) }
        }
        guard archiveGeneration == generation else { return }
        let messageToken = messageGeneration
        if let id = selectedID, !loadingMessages, !paging {
            let following = TimelinePolicy.followsLatest(atBottom: timelineAtBottom, hasLater: hasLater, highlighting: highlightedID != nil)
            let window = try await reader.refresh(messages, conversation: id, followingLatest: following)
            guard archiveGeneration == generation, messageGeneration == messageToken, !paging else { return }
            let pending = try await reader.outbox(conversation: id)
            guard archiveGeneration == generation, messageGeneration == messageToken, !paging else { return }
            // Capture the position before adding rows changes the scrollable
            // height. Apply the rows and their scroll request in one UI update.
            let shouldFollow = following && timelineAtBottom
            apply(window)
            outbox = pending
            if shouldFollow {
                scrollRequest = ScrollRequest(messageID: "timeline-bottom", atBottom: true)
                if windowIsKey && NSApp.isActive { markVisibleAsSeen() }
            }
            if let pendingScrollID, pending.contains(where: { $0.id == pendingScrollID }) {
                scrollRequest = ScrollRequest(messageID: "outbox-" + pendingScrollID, atBottom: true)
                self.pendingScrollID = nil
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
        guard let database else { return }
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
        pendingScrollID = nil
        highlightedID = messageID
        messageTask?.cancel()
        let generation = UUID()
        messageGeneration = generation
        messages = []
        outbox = []
        composerError = nil
        hasEarlier = false
        hasLater = false
        paging = false
        loadingMessages = true
        error = nil
        messageTask = Task {
            do {
                let window: MessageWindow
                if let messageID { window = try await database.around(messageID: messageID, conversation: id) }
                else { window = try await database.latest(conversation: id) }
                guard !Task.isCancelled, messageGeneration == generation else { return }
                let pending = try await database.outbox(conversation: id)
                guard !Task.isCancelled, messageGeneration == generation else { return }
                apply(window)
                outbox = pending
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
    func isUnread(_ conversation: ConversationRecord) -> Bool { seenStore?.isUnread(conversation) ?? false }
    func avatarURL(_ conversation: ConversationRecord) -> URL? { directory.flatMap { conversation.avatarURL(in: $0) } }
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
        guard timestamp > 0, seenStore.markSeen(id, timestamp: timestamp) else { return }
        seenRevision += 1
        updateBadge()
    }
    private func updateBadge() {
        let count = canSync ? unreadCount : 0
        NSApp.dockTile.badgeLabel = count > 0 ? count.formatted() : nil
    }
    private func apply(_ window: MessageWindow) {
        messages = window.messages
        hasEarlier = window.hasEarlier
        hasLater = window.hasLater
    }
    private func readableError(_ error: Error) -> String {
        // Do not put decoded message values, SQL or private paths into alerts.
        (error as? ArchiveFailure)?.localizedDescription ?? "The saved data could not be read. Try another archive or reload after the import finishes."
    }
}
