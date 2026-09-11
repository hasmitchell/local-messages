import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessageComposer: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var focused = false
    @State private var choosingFiles = false
    @State private var editorHeight: CGFloat = 20
    @AppStorage("spellCheck") private var spellCheck = true
    @AppStorage("autocorrect") private var autocorrect = false

    private struct Note { let text: String; let symbol: String; let warning: Bool }
    private var note: Note? {
        if let error = model.composerError { return Note(text: error, symbol: "exclamationmark.circle.fill", warning: true) }
        if model.stagingAttachments { return Note(text: "Preparing attachments…", symbol: "clock", warning: false) }
        if model.draft.submissionID != nil { return Note(text: "Checking send status. Your text is saved.", symbol: "clock", warning: false) }
        if !model.canSync { return Note(text: "Read-only archive. Drafts are saved on this Mac but cannot be sent from here.", symbol: "lock", warning: false) }
        if model.draft.body.unicodeScalars.count > 4000 || model.draft.body.utf8.count > 16000 { return Note(text: "Messages can be up to 4,000 characters.", symbol: "exclamationmark.circle.fill", warning: true) }
        if !model.syncEnabled || !model.syncState.canSend { return Note(text: "Not connected to your phone. Drafts are saved and can be sent once sync reconnects.", symbol: "iphone.slash", warning: false) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.draft.replyTo != nil { ReplyStrip().transition(.move(edge: .bottom).combined(with: .opacity)) }
            if !model.draft.attachments.isEmpty { AttachmentStrip().transition(.move(edge: .bottom).combined(with: .opacity)) }
            HStack(alignment: .bottom, spacing: 4) {
                Button { choosingFiles = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.bouncy).foregroundStyle(.secondary)
                .disabled(model.draft.submissionID != nil || model.stagingAttachments)
                .help("Attach photos or files").accessibilityLabel("Attach files")
                editor
                Button(action: model.sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).frame(width: 28, height: 28)
                }
                .buttonStyle(.bouncy).foregroundStyle(model.canSendDraft ? archiveAccent : Color.secondary.opacity(0.45))
                .scaleEffect(model.canSendDraft ? 1 : 0.9)
                .animation(Motion.bouncy, value: model.canSendDraft)
                .disabled(!model.canSendDraft).accessibilityLabel("Send message").help("Send (⌘Return). Return adds a new line.")
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 4).padding(.trailing, 4).padding(.vertical, 3)
            .background(composerField, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused ? archiveAccent.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
            if let note {
                HStack(spacing: 5) {
                    Image(systemName: note.symbol)
                    Text(note.text)
                    if model.draft.submissionID != nil && !model.syncState.canSend {
                        Button("Check Saved Status", action: model.checkSubmission).controlSize(.mini)
                    }
                }.font(.caption).foregroundStyle(note.warning ? .orange : .secondary).padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .animation(Motion.quick, value: model.draft.replyTo)
        .animation(Motion.quick, value: model.draft.attachments.count)
        .animation(Motion.quick, value: model.composerError)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls) }
        }
    }

    private var editor: some View {
        ComposerTextView(text: Binding(get: { model.draft.body }, set: { model.editDraft($0) }),
                         isEditable: model.draft.submissionID == nil, spellCheck: spellCheck, autocorrect: autocorrect,
                         placeholder: "Message",
                         onHeightChange: { editorHeight = $0 },
                         onFocusChange: { focused = $0 },
                         onAttachFiles: { model.attach($0) },
                         onAttachData: { model.attachData($0, suggestedName: $1) })
            .frame(height: min(max(editorHeight, 22), 150))
            .accessibilityIdentifier("messageComposer").accessibilityLabel("Message composer")
            .padding(.vertical, 3)
    }
}

// What the draft will quote, with a way to drop it.
private struct ReplyStrip: View {
    @EnvironmentObject private var model: ArchiveModel
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(archiveAccent).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to " + (model.replyTarget.map { $0.outgoing ? "yourself" : $0.sender } ?? "an earlier message")).font(.caption.weight(.semibold))
                Text(verbatim: model.replyTarget?.preview ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.setReplyTarget(nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel("Cancel reply").help("Cancel reply")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(composerField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AttachmentStrip: View {
    @EnvironmentObject private var model: ArchiveModel
    private func stagedURL(_ file: DraftAttachment) -> URL? {
        // Staged copies live under the archive's private drafts folder; ids are UUIDs.
        guard let directory = model.directory, file.id.count == 36, file.id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return directory.appendingPathComponent("drafts/attachments/" + file.id)
    }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.draft.attachments) { file in
                    ZStack(alignment: .topTrailing) {
                        if file.mime.hasPrefix("image/"), let url = stagedURL(file) {
                            LocalThumbnail(url: url).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "doc").font(.title3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: file.name).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).foregroundStyle(.secondary)
                                }.font(.caption)
                            }.padding(.horizontal, 10).frame(height: 44).frame(maxWidth: 220)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        Button { model.removeAttachment(file.id) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .gray)
                        }.buttonStyle(.plain).offset(x: 5, y: -5).disabled(model.draft.submissionID != nil).accessibilityLabel("Remove \(file.name)")
                    }.padding(.top, 5).padding(.trailing, 5)
                }
            }.padding(.horizontal, 4)
        }.scrollIndicators(.hidden)
    }
}
