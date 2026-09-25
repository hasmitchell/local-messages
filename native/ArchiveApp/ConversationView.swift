import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationDetail: View {
    @Environment(ArchiveModel.self) private var model
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
        @Bindable var bindable = model
        VStack(spacing: 0) {
            if model.loadingMessages {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty && model.displayedOutbox.isEmpty {
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
                    .popover(isPresented: $bindable.showingDetails, arrowEdge: .bottom) {
                        ConversationInfo(conversation: conversation).frame(width: 500, height: 660)
                    }
            }
        }
        // The find field lives in the toolbar; on macOS 26 it collapses to its icon until used.
        .searchable(text: $bindable.threadQuery, isPresented: $bindable.showingThreadSearch, placement: .toolbar, prompt: "Find in Conversation")
        .onChange(of: model.threadQuery) { model.scheduleThreadSearch() }
        .onChange(of: model.showingThreadSearch) { _, showing in if !showing { model.threadSearchDismissed() } }
    }
}

// The avatar keeps the toolbar's own button chrome and adds hover feedback,
// so it reads as clickable like its neighbours.
private struct AvatarButton: View {
    @Environment(ArchiveModel.self) private var model
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

private struct TimelineEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case separator(String)
        case message(MessageRecord, first: Bool, last: Bool, showsSender: Bool, showsStatus: Bool)
        case pending(OutboxRecord, first: Bool)
    }
    let id: String
    let kind: Kind
}

// Consecutive messages from one sender within five minutes form a group with
// tighter spacing; a gap of more than an hour or a new day gets a time label.
private func timelineEntries(_ messages: [MessageRecord], outbox: [OutboxRecord], submissions: [String: String], group: Bool, calendar: Calendar = .current) -> [TimelineEntry] {
    func continues(_ earlier: MessageRecord, _ later: MessageRecord) -> Bool {
        earlier.outgoing == later.outgoing && earlier.sender == later.sender
            && later.date.timeIntervalSince(earlier.date) < 300 && calendar.isDate(earlier.date, inSameDayAs: later.date)
    }
    let lastOutgoing = outbox.isEmpty ? messages.last(where: \.outgoing)?.id : nil
    var entries: [TimelineEntry] = []
    entries.reserveCapacity(messages.count + 8)
    for (index, message) in messages.enumerated() {
        let previous = index > 0 ? messages[index - 1] : nil
        let next = index + 1 < messages.count ? messages[index + 1] : nil
        let rowID = submissions[message.id].map { "outbox-" + $0 } ?? message.id
        let separator = previous.map { message.date.timeIntervalSince($0.date) > 3600 || !calendar.isDate($0.date, inSameDayAs: message.date) } ?? true
        if separator { entries.append(TimelineEntry(id: "separator-" + rowID, kind: .separator(RelativeDate.separator(message.date)))) }
        let first = separator || previous.map { !continues($0, message) } ?? true
        let continuesToPending = message.outgoing && outbox.first.map { $0.created >= message.timestamp && $0.created - message.timestamp < 300_000_000 } ?? false
        let last = next.map { !continues(message, $0) } ?? !continuesToPending
        let showsStatus = message.outgoing && (message.id == lastOutgoing || message.status.contains("FAILED") || message.deliveryLabel == "Sending")
        entries.append(TimelineEntry(id: rowID, kind: .message(message, first: first, last: last, showsSender: group && !message.outgoing && first, showsStatus: showsStatus)))
    }
    for (index, pending) in outbox.enumerated() {
        let previousTime = index > 0 ? outbox[index - 1].created : messages.last?.timestamp
        let date = Date(timeIntervalSince1970: Double(pending.created) / 1_000_000)
        if pending.created > 0, previousTime.map({ pending.created - $0 > 3_600_000_000 || !calendar.isDate(Date(timeIntervalSince1970: Double($0) / 1_000_000), inSameDayAs: date) }) ?? true {
            entries.append(TimelineEntry(id: "separator-outbox-" + pending.id, kind: .separator(RelativeDate.separator(date))))
        }
        let sameSender = index > 0 || messages.last?.outgoing == true
        let first = !sameSender || previousTime.map { pending.created < $0 || pending.created - $0 >= 300_000_000 } ?? true
        entries.append(TimelineEntry(id: "outbox-" + pending.id, kind: .pending(pending, first: first)))
    }
    return entries
}

private struct MessageTimeline: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: ConversationRecord
    /// Rows depend only on the bubble width, which stays 540 pt unless the
    /// conversation is under 600 pt wide and moves in 20 pt steps below that.
    /// Tracking just that value (not a GeometryReader) keeps a resize or sidebar
    /// slide from rebuilding the timeline: a width change remeasures every row
    /// in one frame, which showed as a snap halfway through the slide.
    @State private var bubbleWidth: CGFloat = 540
    @State private var viewportHeight: CGFloat = 0
    /// Rows well outside this part of the content are drawn as spacers.
    @State private var window: ClosedRange<CGFloat>?
    @State private var heights = RowHeights()
    @State private var measured = 0
    private nonisolated static func bubbleWidth(for width: CGFloat) -> CGFloat {
        let contentWidth = min(1100, width) - 36
        guard contentWidth < 600 else { return 540 }
        return (max(240, contentWidth * 0.9) / 20).rounded(.down) * 20
    }

    var body: some View {
        #if UI_SNAPSHOTS
        let _ = RenderCount.bump("timeline")
        #endif
        // Worked out when messages change, not on each frame of a resize.
        let pending = model.displayedOutbox
        let entries = timelineEntries(model.messages, outbox: pending.filter { !$0.isReaction }, submissions: model.messageSubmissions, group: conversation.isGroup)
        let context = BubbleContext(model: model, conversation: conversation)
        let bubbles = context.states(model.messages, highlighted: model.highlightedID)
        let newSend = "outbox-" + model.sendPulse.uuidString.lowercased()
        ScrollViewReader { reader in
            ScrollView {
                // Message pages are fetched after the selection reaches the UI.
                // Eager layout keeps scroll anchors exact for variable-height media.
                // A LazyVStack was tried (0.8.7): estimated row heights made
                // scrollTo overshoot and bounce, and could land above all rows.
                VStack(spacing: 0) {
                    if model.hasEarlier {
                        LoadMoreButton(title: "Show Earlier Messages") { model.loadMore(earlier: true) }.disabled(model.paging).padding(.bottom, 6)
                    }
                    Color.clear.frame(height: 0).onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("timelineContent")).minY } action: { heights.top = $0 }
                    TimelineRows(model: model, entries: entries, bubbles: bubbles,
                                 directory: context.directory, canReply: context.canReply, bubbleWidth: bubbleWidth, newSend: newSend,
                                 window: window, heights: heights, measured: measured) {
                        // Coalesce: one redraw once a batch of rows has been measured.
                        guard !heights.redrawPending else { return }
                        heights.redrawPending = true
                        Task { @MainActor in heights.redrawPending = false; measured += 1 }
                    }
                    .equatable()
                    ForEach(pending.filter(\.isReaction)) { pending in
                        Text("Reaction \(pending.command?.emoji ?? "") · \(pending.label)").font(.caption)
                            .foregroundStyle(pending.state == "unknown" || pending.state == "failed" ? .orange : .secondary).padding(.top, 8)
                    }
                    if !model.hasLater && model.isTyping(conversation.id) { TypingIndicator() }
                    Color.clear.frame(height: 0).animation(Motion.spring, value: model.isTyping(conversation.id))
                    if model.hasLater {
                        LoadMoreButton(title: "Show Later Messages") { model.loadMore(earlier: false) }.disabled(model.paging).padding(.top, 14)
                    }
                    Color.clear.frame(height: 1).id("timeline-bottom").modifier(BottomEdgeProbe())
                }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 10).frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .coordinateSpace(name: "timelineContent")
            }
            .modifier(VisibleWindow(window: $window))
            .coordinateSpace(name: "timelineViewport")
            .background(TimelineScrollIntent(onScroll: model.userScrolledTimeline))
            .modifier(LegibleToolbarEdge())
            .modifier(ScrollEdgeObserver(edge: .bottom) { if model.timelineAtBottom != $0 { model.timelineAtBottom = $0 } })
            .overlay(alignment: .bottomTrailing) {
                if !model.followingOwnSend && (model.hasLater || !model.timelineAtBottom) {
                    FloatingJumpButton(symbol: "arrow.down", title: "Jump to latest messages", action: model.jumpToLatest)
                    .padding(14)
                    .accessibilityIdentifier("messagesToBottom")
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(Motion.quick, value: model.timelineAtBottom)
            .animation(Motion.quick, value: model.hasLater)
            .onPreferenceChange(TimelineBottomPreference.self) { bottom in
                if #unavailable(macOS 15) {
                    let atBottom = bottom >= 0 && bottom <= viewportHeight + 60
                    if model.timelineAtBottom != atBottom { model.timelineAtBottom = atBottom }
                }
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    if request.animated { try? await Task.sleep(for: .milliseconds(16)) }
                    else { await Task.yield() }
                    guard model.scrollRequest == request else { return }
                    withAnimation(request.animated && !reduceMotion ? Motion.send : nil) {
                        reader.scrollTo(request.atBottom ? "timeline-bottom" : request.messageID, anchor: request.atBottom ? .bottom : .center)
                    }
                }
            }
            .onAppear {
                if let request = model.scrollRequest { reader.scrollTo(request.atBottom ? "timeline-bottom" : request.messageID, anchor: request.atBottom ? .bottom : .center) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { Self.bubbleWidth(for: $0.size.width) } action: { bubbleWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { proxy in
            // Only macOS 14 reads the viewport height (see BottomEdgeProbe).
            if #available(macOS 15, *) { 0 } else { proxy.size.height }
        } action: { viewportHeight = $0 }
    }
}

// The loaded messages. Most model changes (sync status, typing, search, drafts)
// leave these inputs equal, so SwiftUI skips the whole list after one comparison
// instead of diffing every row.
private struct TimelineRows: View, Equatable {
    let model: ArchiveModel
    let entries: [TimelineEntry]
    let bubbles: [String: BubbleState]
    let directory: URL?
    let canReply: Bool
    let bubbleWidth: CGFloat
    let newSend: String
    let window: ClosedRange<CGFloat>?
    let heights: RowHeights
    let measured: Int
    let rowsMeasured: () -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.entries == b.entries && a.bubbles == b.bubbles && a.directory == b.directory && a.canReply == b.canReply
            && a.bubbleWidth == b.bubbleWidth && a.newSend == b.newSend && a.window == b.window && a.heights === b.heights && a.measured == b.measured
    }
    /// Rows drawn in full: those near the visible part of the content, and any
    /// whose height at this width is not known yet. The rest become spacers of
    /// exactly their measured height, so scroll positions stay exact.
    private func fullRows() -> Set<String>? {
        guard let window, heights.width == bubbleWidth else { return nil }
        var full = Set<String>(), y = heights.top, known = true
        for entry in entries {
            guard known, let height = heights.height(entry.id, key: entry.hashValue) else { known = false; full.insert(entry.id); continue }
            if y + height >= window.lowerBound && y <= window.upperBound { full.insert(entry.id) }
            y += height
        }
        return full
    }
    var body: some View {
        #if UI_SNAPSHOTS
        let _ = RenderCount.bump("rows")
        #endif
        let full = fullRows()
        ForEach(entries) { entry in
            if let full, !full.contains(entry.id), let height = heights.height(entry.id, key: entry.hashValue) {
                Color.clear.frame(height: height).id(entry.scrollID)
            } else {
                row(entry)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if heights.record(entry.id, key: entry.hashValue, height: height, width: bubbleWidth) { rowsMeasured() }
                    }
            }
        }
    }
    private func row(_ entry: TimelineEntry) -> some View {
            VStack(spacing: 0) {
                switch entry.kind {
                case .separator(let label):
                    TimelineSeparator(label: label)
                case .message(let message, let first, let last, let showsSender, let showsStatus):
                    let state = bubbles[message.id] ?? BubbleState()
                    MessageBubble(model: model, message: message, first: first, last: last, showsSender: showsSender, showsStatus: showsStatus,
                                  highlighted: state.highlighted, maxWidth: bubbleWidth,
                                  directory: directory, canReply: canReply, reactable: state.reactable,
                                  ownReaction: state.ownReaction, replyOriginal: state.original)
                        .id(message.id)
                case .pending(let message, let first):
                    OutboxBubble(message: message, maxWidth: bubbleWidth, first: first)
                }
            }
            .modifier(SendBubbleEntrance(isNewSend: entry.id == newSend))
            .transition(.identity)
    }
}

extension TimelineEntry {
    /// The id scroll requests use: the message id for messages.
    var scrollID: String {
        if case .message(let message, _, _, _, _) = kind { return message.id }
        return id
    }
}

/// Measured row heights at one bubble width. Written during layout and not
/// observed, so recording a height never causes a redraw by itself.
@MainActor private final class RowHeights {
    private(set) var width: CGFloat = 0
    /// Where the first row starts in the scroll content.
    var top: CGFloat = 0
    var redrawPending = false
    private var heights: [String: (key: Int, height: CGFloat)] = [:]
    func height(_ id: String, key: Int) -> CGFloat? {
        guard let saved = heights[id], saved.key == key else { return nil }
        return saved.height
    }
    /// True when this adds or changes a height.
    func record(_ id: String, key: Int, height: CGFloat, width: CGFloat) -> Bool {
        if width != self.width { heights = [:]; self.width = width }
        if let saved = heights[id], saved.key == key, abs(saved.height - height) < 0.5 { return false }
        heights[id] = (key, height)
        return true
    }
}

/// The visible part of the content plus 400 pt either side, in 200 pt steps
/// so scrolling changes it only now and then.
private struct VisibleWindow: ViewModifier {
    @Binding var window: ClosedRange<CGFloat>?
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
                let visible = geometry.visibleRect, margin: CGFloat = 400, step: CGFloat = 200
                let lower = ((visible.minY - margin) / step).rounded(.down) * step
                return lower...max(lower, ((visible.maxY + margin) / step).rounded(.up) * step)
            } action: { _, value in window = value }
        } else { content }
    }
}

private struct SendBubbleEntrance: ViewModifier {
    let isNewSend: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    private var entering: Bool { isNewSend && !arrived }
    func body(content: Content) -> some View {
        content
            .opacity(entering ? 0 : 1)
            .offset(y: entering && !reduceMotion ? 14 : 0)
            .scaleEffect(entering && !reduceMotion ? 0.97 : 1, anchor: .bottomTrailing)
            .task {
                guard isNewSend else { return }
                await Task.yield()
                withAnimation(Motion.send) { arrived = true }
            }
    }
}

// Wheel/trackpad input cancels send-following; programmatic scroll animation
// does not. Restrict the monitor to this timeline, including on macOS 14.
private struct TimelineScrollIntent: NSViewRepresentable {
    var onScroll: () -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.onScroll = onScroll; view.install(); return view }
    func updateNSView(_ view: Probe, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.uninstall() }
    final class Probe: NSView {
        var onScroll: (() -> Void)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)), event.scrollingDeltaY != 0 {
                    self.onScroll?()
                }
                return event
            }
        }
        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

// macOS 14 has no scroll-geometry callback, so it measures the bottom marker.
// Later systems use ScrollEdgeObserver; there, a geometry preference would only
// add work to every layout of the timeline.
private struct BottomEdgeProbe: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content } else {
            content.background(GeometryReader { proxy in
                Color.clear.preference(key: TimelineBottomPreference.self, value: proxy.frame(in: .named("timelineViewport")).maxY)
            })
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

// What a bubble shows that depends on the rest of the model, worked out once per
// timeline update. Bubbles hold the model only to act on it, never observe it:
// otherwise every change anywhere re-renders every loaded message.
@MainActor private struct BubbleContext {
    let directory: URL?
    let canReply: Bool
    private let model: ArchiveModel
    private let own: Set<String>
    private let byID: [String: MessageRecord]
    init(model: ArchiveModel, conversation: ConversationRecord) {
        self.model = model
        directory = model.directory
        canReply = model.canSync && !model.draftSubmitted
        own = conversation.ownParticipantIDs
        byID = model.messages.contains { $0.replyTo != nil } ? Dictionary(model.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
    }
    /// Per-message values; defaults are left out so the map stays small.
    func states(_ messages: [MessageRecord], highlighted: String?) -> [String: BubbleState] {
        var states: [String: BubbleState] = [:]
        for message in messages {
            let state = BubbleState(highlighted: message.id == highlighted,
                                    reactable: !message.outgoing && model.canReact(message),
                                    ownReaction: message.reactions.isEmpty ? nil : message.reactions.first { !own.isDisjoint(with: $0.participants ?? []) }?.emoji,
                                    original: message.replyTo.flatMap { byID[$0] })
            if state != BubbleState() { states[message.id] = state }
        }
        return states
    }
}
private struct BubbleState: Equatable {
    var highlighted = false
    var reactable = false
    var ownReaction: String?
    var original: MessageRecord?
}

private struct MessageBubble: View {
    let model: ArchiveModel
    let message: MessageRecord
    let first: Bool
    let last: Bool
    let showsSender: Bool
    let showsStatus: Bool
    let highlighted: Bool
    let maxWidth: CGFloat
    let directory: URL?
    let canReply: Bool
    let reactable: Bool
    let ownReaction: String?
    /// The replied-to message when it is in the loaded page.
    let replyOriginal: MessageRecord?
    #if UI_SNAPSHOTS
    @State private var hovering = RenderCount.forceHover
    #else
    @State private var hovering = false
    #endif
    /// Hover controls (time, reply, and the reaction menu, an AppKit pop-up
    /// button) exist only once the pointer has visited. Hundreds of invisible
    /// copies would otherwise be redrawn on every frame of a resize or sidebar slide.
    #if UI_SNAPSHOTS
    @State private var hovered = RenderCount.forceHover
    #else
    @State private var hovered = false
    #endif

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
    private var localURLs: [URL] { directory.map { directory in message.attachments.compactMap { $0.localURL(in: directory) } } ?? [] }
    private var imageOnly: Bool {
        message.body.isEmpty && message.replyTo == nil && !message.attachments.isEmpty
            && message.attachments.allSatisfy(\.isImage) && localURLs.count == message.attachments.count
    }

    // Every loaded row is laid out again on each frame of a window resize or
    // sidebar slide, so the common case (no sender line, no status line, plain
    // text) uses as few layout layers as possible.
    var body: some View {
        rowContent
        .padding(.top, first ? 8 : 2)
        .padding(.bottom, message.reactions.isEmpty ? 0 : 12)
        // The whole row, including the empty space beside the bubble, keeps the
        // hover controls visible while the pointer travels to them.
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside, !hovered else { hovering = inside; return }
            // Build the controls hidden first, then reveal them on the next
            // update so they fade in exactly as on later hovers.
            hovered = true
            Task { @MainActor in hovering = true }
        }
    }

    @ViewBuilder private var rowContent: some View {
        let status = showsStatus && !statusLine.isEmpty
        if showsSender || status {
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
                if showsSender {
                    Text(verbatim: message.sender).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 2)
                }
                placedBubble
                if status {
                    Text(statusLine).font(.caption2).foregroundStyle(message.status.contains("FAILED") ? .red : .secondary).frame(minHeight: 14).padding(.horizontal, 6)
                }
            }
        } else { placedBubble }
    }
    // Frames rather than an HStack with spacers: the text is measured at one
    // fixed width, short messages still hug their content, and at least
    // 24 pt stays free on the far side.
    private var placedBubble: some View {
        bubble.overlay(alignment: message.outgoing ? .leading : .trailing) { sideDetails }
            .frame(maxWidth: maxWidth, alignment: message.outgoing ? .trailing : .leading)
            .padding(message.outgoing ? .leading : .trailing, 24)
            .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
    }

    // Time, transport and reaction controls sit beside the bubble without taking part in its layout.
    // The container stays in place (and carries the alignment guide) whether or
    // not the controls have been built.
    private var sideDetails: some View {
        HStack(spacing: 6) {
            if hovered {
                if message.outgoing { hoverDetail; replyButton } else { reactButton; replyButton; hoverDetail }
            }
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
        // A fixed slot keeps the controls beside the menu from moving.
        Menu { reactionItems } label: {
            Image(systemName: "face.smiling").font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .opacity(hovering && reactable ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.7)
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel("React to message")
        .frame(width: 24, height: 20)
    }
    private var replyButton: some View {
        Button { model.setReplyTarget(message) } label: {
            Image(systemName: "arrowshape.turn.up.left").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 20, height: 20)
        }
        .buttonStyle(.bouncy)
        .opacity(hovering && canReply ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.7)
        .animation(Motion.quick, value: hovering)
        .help("Reply")
        .accessibilityLabel("Reply to message")
    }
    @ViewBuilder private var reactionItems: some View {
        ForEach(quickReactions, id: \.self) { emoji in Button(emoji) { model.react(message, emoji: emoji) } }
        if ownReaction != nil { Divider(); Button("Remove My Reaction") { model.react(message, emoji: "") } }
    }

    @ViewBuilder private var sizedContent: some View {
        if message.reactions.isEmpty { content } else {
            ZStack(alignment: .leading) {
                // A short message still needs room for its reaction badges.
                ReactionBadges(reactions: message.reactions).hidden().frame(height: 0).padding(.horizontal, 12)
                content
            }
        }
    }
    private var bubble: some View {
        sizedContent
        .background(imageOnly ? Color.clear : (message.outgoing ? archiveBubble : incomingBubble), in: shape)
        .overlay { if highlighted { shape.strokeBorder(archiveAccent, lineWidth: 2) } }
        .overlay(alignment: message.outgoing ? .bottomLeading : .bottomTrailing) {
            if !message.reactions.isEmpty {
                ReactionBadges(reactions: message.reactions).padding(.horizontal, 8).offset(y: 11)
                    .transition(.scale(scale: 0.3, anchor: message.outgoing ? .bottomLeading : .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(Motion.bouncy, value: message.reactions)
        .contextMenu {
            if model.canSync { Button("Reply") { model.setReplyTarget(message) }.disabled(!canReply) }
            if !message.outgoing { Menu("React") { reactionItems }.disabled(!reactable) }
            if !message.body.isEmpty {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
            }
            if replyOriginal != nil {
                Button("Show Original Message") { model.showReply(message) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if message.replyTo == nil, message.attachments.isEmpty, !message.body.isEmpty {
            bodyText.padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(message.outgoing ? Color.white : Color.primary)
        } else { richContent }
    }
    private var bodyText: some View {
        Text(MessageText.linkified(message.body)).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
            .tint(message.outgoing ? .white : archiveAccent)
    }
    private var richContent: some View {
        VStack(alignment: .leading, spacing: 6) {

            if let reply = message.replyTo { ReplyQuote(model: model, conversationID: message.conversationID, outgoing: message.outgoing, replyID: reply, original: replyOriginal) }
            ForEach(message.attachments) { attachment in AttachmentView(model: model, directory: directory, attachment: attachment, maxWidth: maxWidth - (imageOnly ? 0 : 24), outgoing: message.outgoing) }
            if !message.body.isEmpty {
                bodyText
            } else if message.attachments.isEmpty {
                Text(message.status.contains("DELETED") ? "Message deleted" : "Message content unavailable").font(.callout).italic().opacity(0.8)
            }
        }
        .padding(.horizontal, imageOnly ? 0 : 12).padding(.vertical, imageOnly ? 0 : 8)
        .foregroundStyle(message.outgoing ? Color.white : Color.primary)
    }
}


private struct ReplyQuote: View {
    let model: ArchiveModel
    let conversationID: String
    let outgoing: Bool
    let replyID: String
    let original: MessageRecord?
    var body: some View {
        Button { model.select(conversationID, messageID: replyID) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(outgoing ? Color.white.opacity(0.85) : archiveAccent).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(original.map { $0.outgoing ? "You" : $0.sender } ?? "Earlier message").font(.caption.weight(.semibold))
                    Text(verbatim: original?.preview ?? "Show the original message").font(.caption).lineLimit(2)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(outgoing ? Color.white.opacity(0.16) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    let model: ArchiveModel
    let directory: URL?
    @State private var showingContact = false
    let attachment: AttachmentRecord
    let maxWidth: CGFloat
    let outgoing: Bool
    private var localURL: URL? { directory.flatMap { attachment.localURL(in: $0) } }

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
    @Environment(ArchiveModel.self) private var model
    let message: OutboxRecord
    let maxWidth: CGFloat
    var first = true
    private var attention: Bool { message.state == "unknown" || message.state == "failed" }
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            VStack(alignment: .leading, spacing: 6) {
                if let reply = message.command?.replyTo { ReplyQuote(model: model, conversationID: message.conversationID, outgoing: true, replyID: reply, original: model.messages.first { $0.id == reply }) }
                ForEach(message.files) { file in Label(file.name, systemImage: file.mime.hasPrefix("image/") ? "photo" : "doc").font(.callout) }
                if !message.body.isEmpty { Text(verbatim: message.body).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).foregroundStyle(.white)
            .background(archiveBubble.opacity(message.state == "failed" ? 0.45 : 1), in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: first ? 18 : 5))
            HStack(spacing: 5) {
                if !attention { ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 10, height: 10) }
                Text(attention ? message.label : message.state == "confirmed" ? "Updating…" : "Sending…").font(.caption2).foregroundStyle(attention ? .orange : .secondary)
            }.frame(minHeight: 14).padding(.horizontal, 6).help(message.label)
            if message.state == "failed" {
                Button("Restore as Draft") { model.restoreDraft(message) }.controlSize(.small)
                    .disabled(!model.draft.body.isEmpty || !model.draft.attachments.isEmpty)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .padding(.top, first ? 8 : 2).padding(.leading, 24).frame(maxWidth: .infinity, alignment: .trailing)
        .id("outbox-" + message.id)
    }
}

// MARK: - Find in conversation

// Results drop down beneath the toolbar find field without pushing the timeline.
private struct ThreadResultsPanel: View {
    @Environment(ArchiveModel.self) private var model
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
