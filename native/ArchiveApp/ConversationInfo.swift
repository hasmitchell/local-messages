import AppKit
import SwiftUI

// Inspector content: contact details plus the conversation's photo, link and file library.
struct ConversationInfo: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var tab = "Photos"
    @State private var contactURL: URL?
    @State private var showingContact = false
    let conversation: ConversationRecord
    private var current: ConversationRecord { model.selectedConversation ?? conversation }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                Picker("Shared items", selection: $tab) { Text("Photos").tag("Photos"); Text("Links").tag("Links"); Text("Files").tag("Files") }
                    .pickerStyle(.segmented).labelsHidden().tint(.accentColor)
                if let error = model.libraryError { Text(error).font(.caption).foregroundStyle(.secondary) }
                if tab == "Photos" { photoGrid } else if tab == "Links" { links } else { files }
                if model.libraryLoading { ProgressView().controlSize(.small).padding(.top, 6) }
                if model.library.hasMore {
                    Button("Search Older Messages") { model.loadLibrary(reset: false, more: true) }.controlSize(.small).disabled(model.libraryLoading)
                }
                Text("From \(model.library.scanned.formatted()) saved messages. Website previews are never fetched.")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 4)
            }.padding(16)
        }
        .task(id: model.selectedID) { model.loadLibrary() }
        .sheet(isPresented: $showingContact) { if let contactURL { ContactPreview(url: contactURL) } }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Avatar(name: current.title, size: 68, group: current.isGroup, imageURL: model.avatarURL(current)).padding(.top, 6)
            Text(current.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).textSelection(.enabled)
            VStack(spacing: 2) {
                ForEach(current.otherParticipants) { person in
                    Text(verbatim: [current.isGroup ? person.name : "", person.number].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if current.numbers.isEmpty { Text("Phone number not available in saved details").font(.caption).foregroundStyle(.tertiary) }
            }
            Text("\(current.messageCount.formatted()) saved messages" + (current.isArchived ? " · Archived" : ""))
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
        }.frame(maxWidth: .infinity)
    }

    private var photoGrid: some View {
        let photos = model.library.files.filter { $0.attachment.isImage }
        return VStack {
            if photos.isEmpty && !model.libraryLoading { empty("No Photos", icon: "photo") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                ForEach(photos) { item in
                    Button { preview(item) } label: {
                        // A square cell sized from the column width; the thumbnail fills and is clipped.
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if let url = model.directory.flatMap({ item.attachment.localURL(in: $0) }) {
                                    LocalThumbnail(url: url)
                                } else {
                                    ZStack { Rectangle().fill(.quaternary); Image(systemName: "photo").foregroundStyle(.secondary) }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }.buttonStyle(.plain)
                        .help(item.message.date.formatted(date: .abbreviated, time: .shortened) + (item.attachment.isDownloaded ? "" : " · Not downloaded"))
                        .accessibilityLabel("Preview photo from \(item.message.date.formatted(date: .abbreviated, time: .omitted))")
                        .contextMenu { Button("Show in Conversation") { jump(item.message) } }
                }
            }
        }
    }
    private var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.library.links.isEmpty && !model.libraryLoading { empty("No Links", icon: "link") }
            ForEach(model.library.links) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "link").font(.system(size: 13)).frame(width: 28, height: 28)
                        .background(archiveAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(archiveAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Link(destination: item.url) { Text(verbatim: item.url.host ?? "Website").font(.callout.weight(.medium)) }
                        Text(verbatim: item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Text(RelativeDate.list(item.message.date)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { Button("Show in Conversation") { jump(item.message) } }
            }
        }
    }
    private var files: some View {
        let files = model.library.files.filter { !$0.attachment.isImage }
        return VStack(alignment: .leading, spacing: 10) {
            if files.isEmpty && !model.libraryLoading { empty("No Files", icon: "doc") }
            ForEach(files) { item in
                Button { preview(item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.attachment.isContact ? "person.crop.rectangle" : "doc").font(.system(size: 13)).frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.attachment.displayName).font(.callout.weight(.medium)).lineLimit(1)
                            Text((item.attachment.isDownloaded ? ByteCountFormatter.string(fromByteCount: item.attachment.size, countStyle: .file) : "Not downloaded") + " · " + RelativeDate.list(item.message.date))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!item.attachment.isDownloaded)
                    .contextMenu { Button("Show in Conversation") { jump(item.message) } }
            }
        }
    }
    private func preview(_ item: SharedFile) {
        guard let url = model.directory.flatMap({ item.attachment.localURL(in: $0) }) else { return }
        if item.attachment.isContact { contactURL = url; showingContact = true }
        else { model.previewURL = url }
    }
    private func jump(_ message: MessageRecord) { model.select(message.conversationID, messageID: message.id) }
    private func empty(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}
