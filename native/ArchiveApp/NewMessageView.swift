import SwiftUI

// Starts a conversation with a phone number. The phone resolves the number to
// an existing thread or creates one; the app then opens it for composing.
struct NewMessageView: View {
    @EnvironmentObject private var model: ArchiveModel
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @FocusState private var focused: Bool

    private var valid: Bool { SendCommand.normalizedNumber(number) != nil }
    private var waiting: Bool { model.pendingStart != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Message").font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Text("To:").foregroundStyle(.secondary)
                TextField("Phone number", text: $number)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .disabled(waiting).onSubmit(start)
                    .accessibilityLabel("Phone number")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(composerField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? archiveAccent.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
            Text(waiting ? "Asking your phone for this conversation…" : model.canStartConversation ? "Include the country code for numbers outside your phone's region. If a conversation with this number already exists, it opens instead." : "Sending needs the phone connection. Wait for the sidebar status to show Connected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.startError {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if waiting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.pendingStart = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start", action: start).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!valid || !model.canStartConversation)
            }
        }
        .padding(22).frame(width: 420)
        .task { await Task.yield(); focused = true }
    }

    private func start() {
        guard valid, model.canStartConversation else { return }
        model.startConversation(with: number)
    }
}
