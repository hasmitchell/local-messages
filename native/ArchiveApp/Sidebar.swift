import AppKit
import SwiftUI

struct ArchiveSidebar: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var awayFromTop = false

    var body: some View {
        Group {
            if model.isSearching { SearchResultsList() } else { conversationList }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatusBar() }
        .modifier(SidebarSearch(query: $model.query, focusToken: model.focusSearch))
        .toolbar { ToolbarItem { AccountMenu() } }
        .onChange(of: model.query) { model.scheduleSearch() }
    }

    private var conversationList: some View {
        ScrollViewReader { reader in
            List(selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })) {
                Section {
                    ForEach(model.visibleConversations) { conversation in
                        ConversationRow(conversation: conversation, unread: model.isUnread(conversation), draft: model.drafts[conversation.id], avatar: model.avatarURL(conversation))
                            .tag(conversation.id).id(conversation.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 10))
                    }
                } header: {
                    if model.overview != nil {
                        Picker("Folder", selection: $model.filter) {
                            ForEach(ConversationFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.bottom, 4)
                    }
                }
            }
            .modifier(ScrollEdgeObserver(edge: .top) { awayFromTop = !$0 })
            .onAppear { if #unavailable(macOS 15) { awayFromTop = true } }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .overlay {
                if model.visibleConversations.isEmpty && !model.loading {
                    ContentUnavailableView(model.overview == nil ? "No Archive Open" : model.filter == .archived ? "No Archived Conversations" : "No Conversations", systemImage: "tray")
                        .scaleEffect(0.8)
                }
            }
            .overlay(alignment: .bottom) {
                if awayFromTop, model.visibleConversations.count > 8, let first = model.visibleConversations.first {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(first.id, anchor: .top) }
                    } label: { Label("Back to top", systemImage: "arrow.up") }
                        .buttonStyle(.plain).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .padding(.bottom, 10).accessibilityIdentifier("conversationsToTop")
                }
            }
        }
    }
}

// The search field lives in the sidebar. macOS 15 can focus it programmatically;
// macOS 14 falls back to locating the field in the window.
private struct SidebarSearch: ViewModifier {
    @Binding var query: String
    let focusToken: UUID
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            FocusableSearch(query: $query, focusToken: focusToken) { content }
        } else {
            content.searchable(text: $query, placement: .sidebar, prompt: "Search")
                .onChange(of: focusToken) { focusSidebarSearchField() }
        }
    }
    @MainActor private func focusSidebarSearchField() {
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView, let field = find(content) else { return }
        window.makeFirstResponder(field)
    }
}

@available(macOS 15, *)
private struct FocusableSearch<Content: View>: View {
    @Binding var query: String
    let focusToken: UUID
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool
    var body: some View {
        content()
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .searchFocused($focused)
            .onChange(of: focusToken) { focused = true }
    }
}

struct ScrollEdgeObserver: ViewModifier {
    let edge: VerticalEdge
    let changed: (Bool) -> Void
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                if edge == .top { geometry.contentOffset.y + geometry.contentInsets.top <= 100 }
                else { geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY <= 60 }
            } action: { _, atEdge in changed(atEdge) }
        } else { content }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationRecord
    let unread: Bool
    let draft: DraftRecord?
    let avatar: URL?
    private var hasDraft: Bool { draft.map { !$0.body.isEmpty || !$0.attachments.isEmpty } == true && draft?.submissionID == nil }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle().fill(archiveAccent).frame(width: 8, height: 8).opacity(unread ? 1 : 0)
                .accessibilityLabel(unread ? "Unread" : "")
            Avatar(name: conversation.title, size: 38, group: conversation.isGroup, imageURL: avatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(conversation.title).font(.system(size: 13, weight: unread ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeDate.list(conversation.date)).font(.system(size: 11)).foregroundStyle(unread ? archiveAccent : .secondary)
                }
                if hasDraft, let draft {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                        Text(verbatim: draft.body.isEmpty ? "Draft with \(draft.attachments.count == 1 ? "an attachment" : "\(draft.attachments.count) attachments")" : "Draft: " + draft.body.replacingOccurrences(of: "\n", with: " "))
                            .lineLimit(2)
                    }.font(.system(size: 12)).foregroundStyle(archiveAccent)
                } else if conversation.isEmpty {
                    Text("No messages in the saved date range").font(.system(size: 12)).italic().foregroundStyle(.tertiary).lineLimit(1)
                } else {
                    Text(verbatim: conversation.preview).font(.system(size: 12)).foregroundStyle(unread ? .primary : .secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SearchResultsList: View {
    @EnvironmentObject private var model: ArchiveModel
    var body: some View {
        List(selection: Binding<String?>(get: { model.highlightedID }, set: { id in
            if let result = model.searchResults.first(where: { $0.id == id }) { model.select(result.conversationID, messageID: result.id) }
        })) {
            if !model.titleMatches.isEmpty {
                Section("Conversations") {
                    ForEach(model.titleMatches.prefix(8)) { conversation in
                        Button { model.select(conversation.id) } label: {
                            HStack(spacing: 10) {
                                Avatar(name: conversation.title, size: 28, group: conversation.isGroup, imageURL: model.avatarURL(conversation))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    if !conversation.numbers.isEmpty { Text(verbatim: conversation.numbers).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Section(model.searching ? "Searching…" : model.searchTotal == 1 ? "1 message" : "\(model.searchTotal.formatted()) messages") {
                if let error = model.searchError { Text(error).font(.callout).foregroundStyle(.secondary) }
                ForEach(model.searchResults) { message in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.conversationTitle(message.conversationID)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(RelativeDate.list(message.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(MessageText.highlighted(message.preview, query: model.query)).font(.system(size: 12)).lineLimit(3).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(message.id)
                }
                if model.searchResults.count >= 10_000 && model.searchTotal > 10_000 {
                    Text("Showing the first 10,000 matches. Refine your search to narrow the results.").font(.caption).foregroundStyle(.secondary)
                } else if model.searchResults.count < model.searchTotal {
                    Button("Load More Results") { model.scheduleSearch(more: true) }.disabled(model.searching)
                }
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden)
        .overlay {
            if !model.searching && model.searchResults.isEmpty && model.titleMatches.isEmpty {
                ContentUnavailableView.search(text: model.query).scaleEffect(0.8)
            }
        }
    }
}

private struct SidebarStatusBar: View {
    @EnvironmentObject private var model: ArchiveModel
    private var statusColor: Color {
        switch model.syncState {
        case .connected, .photosPending: .green
        case .connecting, .catchingUp, .checkingInbox, .checkingArchive, .reconnecting, .incomplete: .orange
        case .pairingRequired, .unavailable, .keychainError, .stopped: .red
        case .local, .paused, .sleeping: Color.secondary
        }
    }
    private var statusLabel: String {
        model.canSync ? model.syncState.label : model.overview == nil ? "No archive open" : "Local archive · read-only"
    }
    private var detail: String? {
        guard let overview = model.overview else { return nil }
        var parts = ["\(overview.messageCount.formatted()) messages", "\(overview.imageCount.formatted()) \(overview.imageCount == 1 ? "photo" : "photos")"]
        if let newest = overview.newest { parts.append("through " + newest.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusLabel).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Menu {
                        if model.canSync {
                            Button(model.syncEnabled ? "Pause Sync" : "Resume Sync", action: model.toggleSync)
                            Button("Reconnect Now", action: model.retrySync)
                            Divider()
                        }
                        Button("Reload Archive", action: model.reload).disabled(model.loading)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Sync options")
                }
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .help(model.canSync ? model.syncState.help : "Saved conversations and search work without a phone connection.")
        }
    }
}
