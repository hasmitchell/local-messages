import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessageComposer: View {
    @Environment(ArchiveModel.self) private var model
    var body: some View { ComposerContent() }
}

private struct ComposerContent: View {
    @Environment(ArchiveModel.self) private var model
    @StateObject private var editorActions = ComposerEditorActions()
    @State private var focused = false
    @State private var choosingFiles = false
    /// One line of 14 pt text plus the 3 pt insets: what the text view measures when empty.
    private static let oneLine = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))) + 6
    @State private var editorHeight: CGFloat = Self.oneLine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("spellCheck") private var spellCheck = true
    @AppStorage("autocorrect") private var autocorrect = false
    @AppStorage("emojiShortcuts") private var emojiShortcuts = true

    private struct Note { let text: String; let symbol: String; let warning: Bool }
    private var note: Note? {
        if let error = model.composerError { return Note(text: error, symbol: "exclamationmark.circle.fill", warning: true) }
        if let voice = editorActions.voiceStatus { return Note(text: voice, symbol: "waveform", warning: voice.contains("Allow") || voice.contains("stopped")) }
        if let notice = model.reactionNotice { return Note(text: notice, symbol: "exclamationmark.circle.fill", warning: true) }
        if model.stagingAttachments { return Note(text: "Preparing attachments…", symbol: "clock", warning: false) }
        if model.draft.submissionID != nil && !model.draftIsInTimeline { return Note(text: "Checking send status. Your text is saved.", symbol: "clock", warning: false) }
        if !model.canSync { return Note(text: "Read-only archive. Drafts are saved on this Mac but cannot be sent from here.", symbol: "lock", warning: false) }
        if model.draft.body.unicodeScalars.count > 4000 || model.draft.body.utf8.count > 16000 { return Note(text: "Messages can be up to 4,000 characters.", symbol: "exclamationmark.circle.fill", warning: true) }
        if !model.syncEnabled || !model.syncState.canSend { return Note(text: "Not connected to your phone. Drafts are saved and can be sent once sync reconnects.", symbol: "iphone.slash", warning: false) }
        return nil
    }

    var body: some View {
        #if UI_SNAPSHOTS
        let _ = RenderCount.bump("composer")
        #endif
        VStack(alignment: .leading, spacing: 6) {
            if model.draft.replyTo != nil && !model.draftIsInTimeline { ReplyStrip().transition(.opacity) }
            if !model.draft.attachments.isEmpty && !model.draftIsInTimeline { AttachmentStrip().transition(.opacity) }
            HStack(alignment: .bottom, spacing: 4) {
                Button { choosingFiles = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.bouncy).foregroundStyle(.secondary)
                .disabled(model.draft.submissionID != nil || model.stagingAttachments)
                .help("Attach photos or files").accessibilityLabel("Attach files")
                editor
                Button(action: editorActions.showEmojiPicker) {
                    Image(systemName: "face.smiling").font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.bouncy).foregroundStyle(.secondary)
                .disabled(model.draft.submissionID != nil)
                .help("Emoji & Symbols (⌃⌘Space)").accessibilityLabel("Insert emoji")
                DictationButton(actions: editorActions)
                    .disabled(model.draft.submissionID != nil)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).frame(width: 28, height: 28)
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? nil : model.sendPulse)
                }
                .buttonStyle(.bouncy).foregroundStyle(model.canSendDraft || editorActions.dictating ? archiveAccent : Color.secondary.opacity(0.45))
                .animation(.easeOut(duration: 0.15), value: model.canSendDraft)
                .disabled(!model.canSendDraft && !editorActions.dictating).accessibilityLabel("Send message").help("Send (Return). Shift-Return adds a new line.")
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
                    if editorActions.voiceStatus?.contains("Privacy & Security") == true {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                        }.controlSize(.mini)
                    }
                }.font(.caption).foregroundStyle(note.warning ? .orange : .secondary).padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .animation(Motion.quick, value: model.draft.replyTo)
        .animation(Motion.quick, value: model.draft.attachments.count)
        .animation(Motion.quick, value: model.composerError)
        .animation(Motion.quick, value: model.reactionNotice)
        .animation(Motion.quick, value: editorActions.voiceStatus)
        .onChange(of: model.sendPulse) { editorHeight = Self.oneLine }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls) }
        }
    }

    /// Sending ends dictation first and waits for its last words, which arrive
    /// after it stops, so they go with the message.
    private func send() {
        guard editorActions.dictating else { model.sendDraft(); return }
        Task { @MainActor in
            await editorActions.finishDictation()
            model.sendDraft()
        }
    }

    private var editor: some View {
        ComposerTextView(text: Binding(get: { model.draftIsInTimeline ? "" : model.draft.body }, set: { model.editDraft($0) }),
                         isEditable: model.draft.submissionID == nil, spellCheck: spellCheck, autocorrect: autocorrect,
                         emojiShortcuts: emojiShortcuts, contextID: (model.directory?.path ?? "") + "/" + (model.selectedID ?? ""), focusToken: model.composerFocus, actions: editorActions,
                         placeholder: editorActions.dictating ? "Listening…" : "Message",
                         onSubmit: send,
                         onHeightChange: { editorHeight = $0 },
                         onFocusChange: { focused = $0 },
                         onAttachFiles: { model.attach($0) },
                         onAttachData: { model.attachData($0, suggestedName: $1) },
                         onAttachImage: { model.attachConverting($0) })
            .frame(height: min(max(editorHeight, Self.oneLine), 150))
            .accessibilityIdentifier("messageComposer").accessibilityLabel("Message composer")
            .padding(.vertical, 3)
    }
}

// Starts and stops voice input in the composer. While listening the microphone
// fills with the accent colour, and a soft disc behind it follows your voice
// (the on-device model) or the symbol pulses (macOS Dictation reports no level).
private struct DictationButton: View {
    @ObservedObject var actions: ComposerEditorActions
    @ObservedObject var meter: VoiceMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(actions: ComposerEditorActions) { self.actions = actions; meter = actions.meter }
    var body: some View {
        Button(action: actions.toggleDictation) {
            Image(systemName: actions.dictating ? "mic.fill" : "mic").font(.system(size: 15, weight: .medium))
                .symbolEffect(.pulse, options: .repeating, isActive: actions.dictating && meter.level == 0 && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(archiveAccent.opacity(actions.dictating ? 0.16 : 0))
                        .scaleEffect(reduceMotion ? 1 : 0.75 + CGFloat(meter.level) * 0.45)
                        .animation(.easeOut(duration: 0.12), value: meter.level)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.bouncy).foregroundStyle(actions.dictating ? archiveAccent : Color.secondary)
        .animation(Motion.quick, value: actions.dictating)
        .help(actions.dictating ? "Stop dictation" : "Dictate a message with macOS Dictation")
        .accessibilityLabel(actions.dictating ? "Stop dictation" : "Dictate")
    }
}

// What the draft will quote, with a way to drop it.
private struct ReplyStrip: View {
    @Environment(ArchiveModel.self) private var model
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
    @Environment(ArchiveModel.self) private var model
    private func stagedURL(_ file: DraftAttachment) -> URL? { model.directory.flatMap(file.stagedURL(in:)) }
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
