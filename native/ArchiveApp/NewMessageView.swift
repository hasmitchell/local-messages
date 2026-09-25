import SwiftUI

// Starts a conversation with a contact or phone number. The phone resolves the
// number to an existing thread or creates one; the app then opens it.
struct NewMessageView: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ContactEntry] = []
    @State private var hasContacts = true
    @FocusState private var focused: Bool

    private var valid: Bool { SendCommand.normalizedNumber(query) != nil }
    private var waiting: Bool { model.pendingStart != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message").font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Text("To:").foregroundStyle(.secondary)
                TextField("Name or phone number", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .disabled(waiting).onSubmit(startTyped)
                    .accessibilityLabel("Name or phone number")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(composerField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? archiveAccent.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
            if !results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { entry in
                            Button { start(entry.number) } label: {
                                HStack(spacing: 10) {
                                    Avatar(name: entry.title, size: 30, imageURL: model.contactAvatarURL(entry))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: entry.title).font(.callout.weight(.medium)).lineLimit(1)
                                        if !entry.name.isEmpty { Text(verbatim: entry.number).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(waiting || !model.canStartConversation)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(waiting ? "Asking your phone for this conversation…"
                 : !model.canStartConversation ? "Sending needs the phone connection. Wait for the sidebar status to show Connected."
                 : !hasContacts ? "Your phone's contacts appear here after the first sync. You can also type a number; include the country code for numbers outside your phone's region."
                 : "Pick a contact, or type a number. If a conversation already exists, it opens instead.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.startError {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if waiting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.pendingStart = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start", action: startTyped).prominentButton().keyboardShortcut(.defaultAction)
                    .disabled(!valid || !model.canStartConversation)
            }
        }
        .padding(22).frame(width: 440)
        .task { await Task.yield(); focused = true }
        .task(id: query) {
            hasContacts = await model.hasContacts()
            results = query.trimmingCharacters(in: .whitespaces).isEmpty ? Array((await model.searchContacts("")).prefix(8)) : await model.searchContacts(query)
        }
    }

    private func startTyped() {
        guard valid, model.canStartConversation else { return }
        model.startConversation(with: query)
    }
    private func start(_ number: String) {
        guard model.canStartConversation else { return }
        query = number
        model.startConversation(with: number)
    }
}
