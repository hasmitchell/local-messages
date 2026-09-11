import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessageComposer: View {
    @EnvironmentObject private var model: ArchiveModel
    @FocusState private var focused: Bool
    @State private var choosingFiles = false
    @State private var editorWidth: CGFloat = 400

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
            if !model.draft.attachments.isEmpty { AttachmentStrip() }
            HStack(alignment: .bottom, spacing: 4) {
                Button { choosingFiles = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(model.draft.submissionID != nil || model.stagingAttachments)
                .help("Attach photos or files").accessibilityLabel("Attach files")
                editor
                Button(action: model.sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(model.canSendDraft ? archiveAccent : Color.secondary.opacity(0.45))
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
        .onChange(of: model.showingThreadSearch) { _, showing in if showing { focused = false } }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls) }
        }
    }

    // Height follows the wrapped text for the current editor width. Measuring
    // with AppKit avoids a SwiftUI layout feedback loop between a hidden twin
    // view and the editor frame.
    private var editorHeight: CGFloat {
        let body = model.draft.body
        let text = body.isEmpty ? " " : body + (body.hasSuffix("\n") ? " " : "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph])
        let bounds = attributed.boundingRect(with: CGSize(width: max(40, editorWidth - 10), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(max(ceil(bounds.height) + 6, 22), 150)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(get: { model.draft.body }, set: { model.editDraft($0) }))
                .font(.system(size: 14)).lineSpacing(1).focused($focused).scrollContentBackground(.hidden)
                .frame(height: editorHeight)
                .background(GeometryReader { proxy in Color.clear.preference(key: ComposerWidthPreference.self, value: proxy.size.width) })
                .disabled(model.draft.submissionID != nil)
                .accessibilityIdentifier("messageComposer").accessibilityLabel("Message composer")
            if model.draft.body.isEmpty {
                Text("Message").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 2).allowsHitTesting(false)
            }
        }
        .onPreferenceChange(ComposerWidthPreference.self) { width in
            if abs(width - editorWidth) > 0.5 { editorWidth = width }
        }
        .padding(.vertical, 3)
    }
}

private struct ComposerWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
