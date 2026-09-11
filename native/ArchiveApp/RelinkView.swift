import SwiftUI

struct RelinkView: View {
    @EnvironmentObject private var model: ArchiveModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: RelinkController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: controller.state == .complete ? "checkmark.circle.fill" : "link")
                    .font(.title).foregroundStyle(.tint)
                Text(controller.state.title).font(.title2.weight(.semibold))
            }
            Text(controller.state.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let emoji = controller.emoji, controller.state == .waitingForPhone {
                Text(emoji).font(.system(size: 72)).frame(maxWidth: .infinity)
                    .accessibilityLabel("Pairing emoji: \(emoji)")
            } else if controller.busy {
                ProgressView().frame(maxWidth: .infinity)
            }
            if controller.state == .ready {
                Text("Sync pauses during pairing. Keep your phone nearby. This usually takes a minute or two.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if controller.busy {
                    Button("Cancel", action: controller.cancel).disabled(controller.state == .cancelling)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    if controller.state != .complete {
                        Button(controller.state == .ready ? "Sign In & Reconnect…" : "Try Again…") { model.reconnectArchive() }
                            .prominentButton().keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(24).frame(width: 470)
        .interactiveDismissDisabled(controller.busy)
    }
}
