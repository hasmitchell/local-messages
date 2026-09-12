import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationDetail: View {
    @EnvironmentObject private var model: ArchiveModel
    let conversation: ConversationRecord

    private var subtitle: String {
        var parts: [String] = []
        if conversation.isGroup {
            parts.append(conversation.otherParticipants.map { $0.name.isEmpty ? $0.number : $0.name }.filter { !$0.isEmpty }.joined(separator: ", "))
        } else if !conversation.numbers.isEmpty, !Self.sameNumber(conversation.title, conversation.numbers) {
            parts.append(conversation.numbers)
        }
        if conversation.isArchived { parts.append("Archived") }
        return parts.joined(separator: " · ")
    }
    /// "0497 573 812" and "+61497573812" are the same number written two ways.
    private static func sameNumber(_ a: String, _ b: String) -> Bool {
        let digitsA = a.filter(\.isNumber), digitsB = b.filter(\.isNumber)
        guard digitsA.count >= 6, digitsB.count >= 6 else { return false }
        return digitsA.hasSuffix(String(digitsB.suffix(8))) || digitsB.hasSuffix(String(digitsA.suffix(8)))
    }

    @State private var dropTargeted = false
    var body: some View {
        VStack(spacing: 0) {
            if model.loadingMessages {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty && model.outbox.isEmpty {
                ContentUnavailableView("No Saved Messages", systemImage: "tray", description: Text("This conversation has no messages in the saved date range."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { MessageTimeline(conversation: conversation) }
            Divider()
            MessageComposer()
        }
        .overlay(alignment: .topTrailing) {
            if model.showingThreadSearch && !model.threadQuery.trimmingCharacters(in: .whitespaces).isEmpty { ThreadResultsPanel() }
        }
        .animation(Motion.quick, value: model.showingThreadSearch && !model.threadQuery.isEmpty)
        .overlay {
            if dropTargeted {
                ZStack {
                    Rectangle().fill(archiveAccent.opacity(0.08))
                    VStack(spacing: 8) {
                        Image(systemName: "paperclip.circle.fill").font(.system(size: 40)).foregroundStyle(archiveAccent)
                        Text("Drop to attach").font(.headline)
                    }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: dropTargeted)
        // Files or images dropped anywhere on the conversation are staged as attachments.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            guard model.canSync else { return false }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        guard let url else { return }
                        Task { @MainActor in model.attach([url]) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        guard let data, let image = NSImage(data: data), let png = PastedImage.png(from: image) else { return }
                        Task { @MainActor in model.attachData(png, suggestedName: "Dropped image.png") }
                    }
                }
            }
            return true
        }
        .navigationTitle(conversation.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AvatarButton(conversation: conversation)
                    .popover(isPresented: $model.showingDetails, arrowEdge: .bottom) {
                        ConversationInfo(conversation: conversation).frame(width: 500, height: 660)
                    }
            }
        }
        // The find field lives in the toolbar; on macOS 26 it collapses to its icon until used.
        .searchable(text: $model.threadQuery, isPresented: $model.showingThreadSearch, placement: .toolbar, prompt: "Find in Conversation")
        .onChange(of: model.threadQuery) { model.scheduleThreadSearch() }
        .onChange(of: model.showingThreadSearch) { _, showing in if !showing { model.threadSearchDismissed() } }
    }
}

// The avatar keeps the toolbar's own button chrome and adds hover feedback,
// so it reads as clickable like its neighbours.
private struct AvatarButton: View {
    @EnvironmentObject private var model: ArchiveModel
    let conversation: ConversationRecord
    @State private var hovering = false
    var body: some View {
        Button(action: model.toggleDetails) {
            Avatar(name: conversation.title, size: 24, group: conversation.isGroup, imageURL: model.avatarURL(conversation))
                .overlay(Circle().strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.12), lineWidth: 1))
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .padding(2)
        }
        .onHover { hovering = $0 }
        .help("Contact details, photos, links and files (⌘I)")
        .accessibilityLabel("Conversation details")
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
                    if !model.hasLater && model.isTyping(conversation.id) { TypingIndicator() }
                    Color.clear.frame(height: 0).animation(Motion.spring, value: model.isTyping(conversation.id))
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
                    FloatingJumpButton(symbol: "arrow.down", title: "Jump to latest messages") {
                        if model.hasLater { model.showLatest() }
                        else {
                            model.highlightedID = nil
                            withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("timeline-bottom", anchor: .bottom) }
                        }
                    }
                    .padding(14)
                    .accessibilityIdentifier("messagesToBottom")
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(Motion.quick, value: model.timelineAtBottom)
            .animation(Motion.quick, value: model.hasLater)
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

// Three pulsing dots in an incoming bubble while the other side types.
private struct TypingIndicator: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                    .opacity(phase == index ? 1 : 0.4)
                    .offset(y: phase == index ? -4 : 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(incomingBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
        .accessibilityLabel("Typing")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(330))
                withAnimation(Motion.bouncy) { phase = (phase + 1) % 3 }
            }
        }
    }
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
        // The whole row, including the empty space beside the bubble, keeps the
        // hover controls visible while the pointer travels to them.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: message.outgoing ? .bottomTrailing : .bottomLeading)),
            removal: .opacity))
    }

    // Time, transport and reaction controls sit beside the bubble without taking part in its layout.
    private var sideDetails: some View {
        HStack(spacing: 6) {
            if message.outgoing { hoverDetail; replyButton } else { reactButton; replyButton; hoverDetail }
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
        .scaleEffect(hovering ? 1 : 0.7)
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel("React to message")
    }
    private var replyButton: some View {
        Button { model.setReplyTarget(message) } label: {
            Image(systemName: "arrowshape.turn.up.left").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 20, height: 20)
        }
        .buttonStyle(.bouncy)
        .opacity(hovering && model.canSync && model.draft.submissionID == nil ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.7)
        .animation(Motion.quick, value: hovering)
        .help("Reply")
        .accessibilityLabel("Reply to message")
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
            if !message.reactions.isEmpty {
                ReactionBadges(reactions: message.reactions).padding(.horizontal, 8).offset(y: 11)
                    .transition(.scale(scale: 0.3, anchor: message.outgoing ? .bottomLeading : .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(Motion.bouncy, value: message.reactions)
        .contextMenu {
            if model.canSync { Button("Reply") { model.setReplyTarget(message) }.disabled(model.draft.submissionID != nil) }
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
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)), removal: .opacity))
    }
}

// MARK: - Find in conversation

// Results drop down beneath the toolbar find field without pushing the timeline.
private struct ThreadResultsPanel: View {
    @EnvironmentObject private var model: ArchiveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.threadSearching { ProgressView().controlSize(.small) }
                Text(model.threadSearching ? "Searching…" : model.threadTotal == 1 ? "1 match" : "\(model.threadTotal.formatted()) matches")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button { model.showingThreadSearch = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Close find results").help("Close (Esc)")
            }.padding(.horizontal, 4)
            if let error = model.threadError { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
            if !model.threadResults.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.threadResults) { message in
                            Button { model.select(message.conversationID, messageID: message.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(MessageText.highlighted(message.preview, query: model.threadQuery)).font(.callout).lineLimit(2)
                                    Text((message.outgoing ? "You · " : "") + RelativeDate.list(message.date)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.highlightedID == message.id ? archiveAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if model.threadResults.count < model.threadTotal {
                            Button("More Results") { model.scheduleThreadSearch(more: true) }.controlSize(.small).padding(6)
                        }
                    }
                }.frame(maxHeight: 280)
            } else if !model.threadSearching {
                Text("No matches in this conversation").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.bottom, 2)
            }
        }
        .padding(8).frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(10)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("threadSearchResults")
    }
}
