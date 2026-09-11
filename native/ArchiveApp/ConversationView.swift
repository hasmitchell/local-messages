import AppKit
import SwiftUI

struct ConversationDetail: View {
    @EnvironmentObject private var model: ArchiveModel
    let conversation: ConversationRecord

    private var subtitle: String {
        var parts: [String] = []
        if conversation.isGroup {
            parts.append(conversation.otherParticipants.map { $0.name.isEmpty ? $0.number : $0.name }.filter { !$0.isEmpty }.joined(separator: ", "))
        } else if !conversation.numbers.isEmpty, conversation.numbers != conversation.title {
            parts.append(conversation.numbers)
        }
        if conversation.isArchived { parts.append("Archived") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.showingThreadSearch { ThreadSearchView(); Divider() }
            if model.loadingMessages {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty && model.outbox.isEmpty {
                ContentUnavailableView("No Saved Messages", systemImage: "tray", description: Text("This conversation has no messages in the saved date range."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { MessageTimeline(conversation: conversation) }
            Divider()
            MessageComposer()
        }
        .navigationTitle(conversation.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.toggleThreadSearch) { Label("Find in Conversation", systemImage: "magnifyingglass") }
                    .help("Find in this conversation (⌘F)")
                Toggle(isOn: $model.showingDetails) { Label("Conversation Info", systemImage: "info.circle") }
                    .help("Contact details, photos, links and files (⌘I)")
            }
        }
    }
}

// MARK: - Timeline

private struct TimelineEntry: Identifiable {
    enum Kind {
        case separator(String)
        case message(MessageRecord, first: Bool, last: Bool, showsSender: Bool, showsStatus: Bool)
    }
    let id: String
    let kind: Kind
}

// Consecutive messages from one sender within five minutes form a group with
// tighter spacing; a gap of more than an hour or a new day gets a time label.
private func timelineEntries(_ messages: [MessageRecord], group: Bool, calendar: Calendar = .current) -> [TimelineEntry] {
    func continues(_ earlier: MessageRecord, _ later: MessageRecord) -> Bool {
        earlier.outgoing == later.outgoing && earlier.sender == later.sender
            && later.date.timeIntervalSince(earlier.date) < 300 && calendar.isDate(earlier.date, inSameDayAs: later.date)
    }
    let lastOutgoing = messages.last(where: \.outgoing)?.id
    var entries: [TimelineEntry] = []
    entries.reserveCapacity(messages.count + 8)
    for (index, message) in messages.enumerated() {
        let previous = index > 0 ? messages[index - 1] : nil
        let next = index + 1 < messages.count ? messages[index + 1] : nil
        let separator = previous.map { message.date.timeIntervalSince($0.date) > 3600 || !calendar.isDate($0.date, inSameDayAs: message.date) } ?? true
        if separator { entries.append(TimelineEntry(id: "separator-" + message.id, kind: .separator(RelativeDate.separator(message.date)))) }
        let first = separator || previous.map { !continues($0, message) } ?? true
        let last = next.map { !continues(message, $0) } ?? true
        let showsStatus = message.outgoing && (message.id == lastOutgoing || message.status.contains("FAILED") || message.deliveryLabel == "Sending")
        entries.append(TimelineEntry(id: message.id, kind: .message(message, first: first, last: last, showsSender: group && !message.outgoing && first, showsStatus: showsStatus)))
    }
    return entries
}

private struct MessageTimeline: View {
    @EnvironmentObject private var model: ArchiveModel
    let conversation: ConversationRecord

    var body: some View {
        GeometryReader { geometry in
        ScrollViewReader { reader in
            ScrollView {
                let entries = timelineEntries(model.messages, group: conversation.isGroup)
                let contentWidth = min(1100, geometry.size.width) - 36
                let bubbleWidth = min(540, max(240, contentWidth * 0.72))
                // Pages are bounded to 100 messages. Eager layout gives stable
                // geometry for scroll-to-result and latest-message positioning.
                VStack(spacing: 0) {
                    if model.hasEarlier {
                        LoadMoreButton(title: "Show Earlier Messages") { model.loadMore(earlier: true) }.disabled(model.paging).padding(.bottom, 6)
                    }
                    ForEach(entries) { entry in
                        switch entry.kind {
                        case .separator(let label):
                            TimelineSeparator(label: label)
                        case .message(let message, let first, let last, let showsSender, let showsStatus):
                            MessageBubble(message: message, first: first, last: last, showsSender: showsSender, showsStatus: showsStatus,
                                          highlighted: model.highlightedID == message.id, maxWidth: bubbleWidth, spare: max(24, contentWidth - bubbleWidth))
                                .id(message.id)
                        }
                    }
                    ForEach(model.outbox.filter { !$0.isReaction }) { pending in OutboxBubble(message: pending, spare: contentWidth - bubbleWidth) }
                    ForEach(model.outbox.filter(\.isReaction)) { pending in
                        Text("Reaction \(pending.command?.emoji ?? "") · \(pending.label)").font(.caption)
                            .foregroundStyle(pending.state == "unknown" || pending.state == "failed" ? .orange : .secondary).padding(.top, 8)
                    }
                    if model.hasLater {
                        LoadMoreButton(title: "Show Later Messages") { model.loadMore(earlier: false) }.disabled(model.paging).padding(.top, 14)
                    }
                    Color.clear.frame(height: 1).id("timeline-bottom").background(GeometryReader { proxy in
                        Color.clear.preference(key: TimelineBottomPreference.self, value: proxy.frame(in: .named("timelineViewport")).maxY)
                    })
                }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 10).frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "timelineViewport")
            .modifier(ScrollEdgeObserver(edge: .bottom) { model.timelineAtBottom = $0 })
            .overlay(alignment: .bottomTrailing) {
                if model.hasLater || !model.timelineAtBottom {
                    Button {
                        if model.hasLater { model.showLatest() }
                        else {
                            model.highlightedID = nil
                            withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("timeline-bottom", anchor: .bottom) }
                        }
                    } label: { Image(systemName: "arrow.down").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34) }
                        .buttonStyle(.plain).foregroundStyle(archiveAccent)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                        .padding(14).help("Jump to latest messages")
                        .accessibilityLabel("Jump to latest messages").accessibilityIdentifier("messagesToBottom")
                }
            }
            .onPreferenceChange(TimelineBottomPreference.self) { bottom in
                if #unavailable(macOS 15) { model.timelineAtBottom = bottom >= 0 && bottom <= geometry.size.height + 60 }
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    await Task.yield()
                    reader.scrollTo(request.atBottom ? "timeline-bottom" : request.messageID, anchor: request.atBottom ? .bottom : .center)
                }
            }
            .onAppear {
                if let request = model.scrollRequest { reader.scrollTo(request.atBottom ? "timeline-bottom" : request.messageID, anchor: request.atBottom ? .bottom : .center) }
            }
        }
        }
    }
}

private struct TimelineBottomPreference: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TimelineSeparator: View {
    let label: String
    var body: some View {
        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 4)
    }
}

private struct LoadMoreButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Bubbles

private let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "👎"]

private struct MessageBubble: View {
    @EnvironmentObject private var model: ArchiveModel
    let message: MessageRecord
    let first: Bool
    let last: Bool
    let showsSender: Bool
    let showsStatus: Bool
    let highlighted: Bool
    let maxWidth: CGFloat
    /// Space kept free beside the bubble; limiting the proposal this way lets the bubble hug its text.
    let spare: CGFloat
    @State private var hovering = false

    private var shape: UnevenRoundedRectangle {
        let big: CGFloat = 18, small: CGFloat = 5
        if message.outgoing {
            return UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: last ? big : small, topTrailingRadius: first ? big : small, style: .continuous)
        }
        return UnevenRoundedRectangle(topLeadingRadius: first ? big : small, bottomLeadingRadius: last ? big : small, bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
    }
    private var transport: String? { ["SMS", "MMS", "RCS"].contains(message.transport) ? message.transport : nil }
    private var statusLine: String { [message.deliveryLabel, transport].compactMap { $0 }.joined(separator: " · ") }
    private var hoverLabel: String {
        var parts = [RelativeDate.time(message.date)]
        if let transport { parts.append(transport) }
        if message.outgoing, !showsStatus, let label = message.deliveryLabel { parts.append(label) }
        return parts.joined(separator: " · ")
    }
    private var localURLs: [URL] { model.directory.map { directory in message.attachments.compactMap { $0.localURL(in: directory) } } ?? [] }
    private var imageOnly: Bool {
        message.body.isEmpty && message.replyTo == nil && !message.attachments.isEmpty
            && message.attachments.allSatisfy(\.isImage) && localURLs.count == message.attachments.count
    }

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
            if showsSender {
                Text(verbatim: message.sender).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 2)
            }
            HStack(spacing: 0) {
                if message.outgoing { Spacer(minLength: spare) }
                // Priority sizes the bubble before the spacer, so text wraps at the
                // intended width and short messages still hug their content.
                bubble.overlay(alignment: message.outgoing ? .leading : .trailing) { sideDetails }.layoutPriority(1)
                if !message.outgoing { Spacer(minLength: spare) }
            }
            if showsStatus, !statusLine.isEmpty {
                Text(statusLine).font(.caption2).foregroundStyle(message.status.contains("FAILED") ? .red : .secondary).padding(.horizontal, 6)
            }
        }
        .padding(.top, first ? 8 : 2)
        .padding(.bottom, message.reactions.isEmpty ? 0 : 12)
        .onHover { hovering = $0 }
    }

    // Time, transport and reaction controls sit beside the bubble without taking part in its layout.
    private var sideDetails: some View {
        HStack(spacing: 6) {
            if message.outgoing { hoverDetail } else { reactButton; hoverDetail }
        }
        .fixedSize()
        .alignmentGuide(message.outgoing ? .leading : .trailing) { dimensions in
            message.outgoing ? dimensions[.trailing] + 8 : dimensions[.leading] - 8
        }
    }
    private var hoverDetail: some View {
        Text(hoverLabel).font(.caption2).foregroundStyle(.tertiary).fixedSize()
            .opacity(hovering ? 1 : 0).animation(.easeInOut(duration: 0.12), value: hovering)
            .accessibilityHidden(!hovering)
    }
    private var reactButton: some View {
        Menu { reactionItems } label: {
            Image(systemName: "face.smiling").font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .opacity(hovering && model.canReact(message) ? 1 : 0)
        .accessibilityLabel("React to message")
    }
    @ViewBuilder private var reactionItems: some View {
        ForEach(quickReactions, id: \.self) { emoji in Button(emoji) { model.react(message, emoji: emoji) } }
        if model.ownReaction(message) != nil { Divider(); Button("Remove My Reaction") { model.react(message, emoji: "") } }
    }

    private var bubble: some View {
        ZStack(alignment: .leading) {
            if !message.reactions.isEmpty {
                // A short message still needs room for its reaction badges.
                ReactionBadges(reactions: message.reactions).hidden().frame(height: 0).padding(.horizontal, 12)
            }
            content
        }
        .background(imageOnly ? Color.clear : (message.outgoing ? archiveBubble : incomingBubble), in: shape)
        .overlay(shape.strokeBorder(highlighted ? archiveAccent : .clear, lineWidth: 2))
        .overlay(alignment: message.outgoing ? .bottomLeading : .bottomTrailing) {
            if !message.reactions.isEmpty { ReactionBadges(reactions: message.reactions).padding(.horizontal, 8).offset(y: 11) }
        }
        .contextMenu {
            if !message.outgoing { Menu("React") { reactionItems }.disabled(!model.canReact(message)) }
            if !message.body.isEmpty {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
            }
            if let reply = message.replyTo, model.messages.contains(where: { $0.id == reply }) {
                Button("Show Original Message") { model.showReply(message) }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {

            if let reply = message.replyTo { ReplyQuote(message: message, replyID: reply) }
            ForEach(message.attachments) { attachment in AttachmentView(attachment: attachment, maxWidth: maxWidth - (imageOnly ? 0 : 24), outgoing: message.outgoing) }
            if !message.body.isEmpty {
                Text(MessageText.linkified(message.body)).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                    .tint(message.outgoing ? .white : archiveAccent)
            } else if message.attachments.isEmpty {
                Text(message.status.contains("DELETED") ? "Message deleted" : "Message content unavailable").font(.callout).italic().opacity(0.8)
            }
        }
        .padding(.horizontal, imageOnly ? 0 : 12).padding(.vertical, imageOnly ? 0 : 8)
        .foregroundStyle(message.outgoing ? Color.white : Color.primary)
    }
}


private struct ReplyQuote: View {
    @EnvironmentObject private var model: ArchiveModel
    let message: MessageRecord
    let replyID: String
    var body: some View {
        let original = model.messages.first { $0.id == replyID }
        Button { model.showReply(message) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(message.outgoing ? Color.white.opacity(0.85) : archiveAccent).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(original.map { $0.outgoing ? "You" : $0.sender } ?? "Earlier message").font(.caption.weight(.semibold))
                    Text(verbatim: original?.preview ?? "Show the original message").font(.caption).lineLimit(2)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(message.outgoing ? Color.white.opacity(0.16) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.buttonStyle(.plain).help("Show the replied-to message")
    }
}

private struct ReactionBadges: View {
    let reactions: [ReactionRecord]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(reactions.enumerated()), id: \.offset) { _, reaction in
                Text(reaction.emoji + (reaction.count > 1 ? " \(reaction.count)" : ""))
                    .font(.system(size: 11)).foregroundStyle(Color.primary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            }
        }.fixedSize().help("Reactions")
    }
}

private struct AttachmentView: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var showingContact = false
    let attachment: AttachmentRecord
    let maxWidth: CGFloat
    let outgoing: Bool
    private var localURL: URL? { model.directory.flatMap { attachment.localURL(in: $0) } }

    var body: some View {
        if let url = localURL {
            Button { preview(url) } label: {
                if attachment.isImage {
                    let size = ImageSizeCache.shared.size(for: url).map { ImageSizeCache.fit($0, into: CGSize(width: min(320, maxWidth), height: 340)) } ?? CGSize(width: 240, height: 180)
                    LocalThumbnail(url: url).frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else { fileLabel(saved: true) }
            }.buttonStyle(.plain)
                .accessibilityLabel("Preview \(attachment.displayName)")
                .help(attachment.isContact ? "View shared contact" : "Open in Quick Look")
                .sheet(isPresented: $showingContact) { ContactPreview(url: url) }
                .contextMenu {
                    Button(attachment.isContact ? "View Contact" : "Quick Look") { preview(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
        } else { fileLabel(saved: false) }
    }
    private func preview(_ url: URL) {
        if attachment.isContact { showingContact = true } else { model.previewURL = url }
    }
    private func fileLabel(saved: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.isImage ? "photo" : attachment.isContact ? "person.crop.rectangle" : "doc")
                .font(.system(size: 16)).frame(width: 34, height: 34)
                .background(outgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: attachment.displayName).font(.callout.weight(.medium)).lineLimit(2)
                Text(saved ? (attachment.isContact ? "Contact card · " : "") + ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file) : "Not saved on this Mac")
                    .font(.caption).opacity(0.7)
            }
        }.padding(.vertical, 2).frame(maxWidth: 260, alignment: .leading)
    }
}

struct OutboxBubble: View {
    @EnvironmentObject private var model: ArchiveModel
    let message: OutboxRecord
    let spare: CGFloat
    private var attention: Bool { message.state == "unknown" || message.state == "failed" }
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(message.files) { file in Label(file.name, systemImage: file.mime.hasPrefix("image/") ? "photo" : "doc").font(.callout) }
                if !message.body.isEmpty { Text(verbatim: message.body).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).foregroundStyle(.white)
            .background(archiveBubble.opacity(message.state == "failed" ? 0.45 : 0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 5) {
                if ["preparing", "sending", "accepted", "confirmed"].contains(message.state) { ProgressView().controlSize(.mini) }
                Text(message.label).font(.caption2).foregroundStyle(attention ? .orange : .secondary)
            }.padding(.horizontal, 6)
            if message.state == "failed" {
                Button("Restore as Draft") { model.restoreDraft(message) }.controlSize(.small)
                    .disabled(!model.draft.body.isEmpty || !model.draft.attachments.isEmpty)
            }
        }
        .padding(.top, 8).padding(.leading, max(24, spare)).frame(maxWidth: .infinity, alignment: .trailing)
        .id("outbox-" + message.id)
    }
}

// MARK: - Find in conversation

private struct ThreadSearchView: View {
    @EnvironmentObject private var model: ArchiveModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in conversation", text: $model.threadQuery).textFieldStyle(.plain).focused($focused).accessibilityIdentifier("threadSearch")
                if model.threadSearching { ProgressView().controlSize(.small) }
                else if !model.threadQuery.isEmpty {
                    Text(model.threadTotal == 1 ? "1 match" : "\(model.threadTotal.formatted()) matches").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button(action: model.toggleThreadSearch) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Close conversation search").help("Close (Esc)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(composerField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            if let error = model.threadError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !model.threadResults.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.threadResults) { message in
                            Button { model.select(message.conversationID, messageID: message.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(MessageText.highlighted(message.preview, query: model.threadQuery)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(RelativeDate.list(message.date)).foregroundStyle(.secondary).font(.caption)
                                }.font(.callout).padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(model.highlightedID == message.id ? archiveAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if model.threadResults.count < model.threadTotal {
                            Button("More Results") { model.scheduleThreadSearch(more: true) }.controlSize(.small).padding(.top, 4)
                        }
                    }
                }.frame(maxHeight: 170)
            } else if !model.threadQuery.isEmpty && !model.threadSearching {
                Text("No matches in this conversation").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
        .onAppear { if !model.threadQuery.isEmpty { model.scheduleThreadSearch() } }
        .onChange(of: model.threadQuery) { model.scheduleThreadSearch() }
        .onExitCommand { model.toggleThreadSearch() }
        .task(id: model.focusThreadSearch) {
            // Wait until the newly inserted field has joined the window's
            // focus tree before taking focus from the composer.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
    }
}
