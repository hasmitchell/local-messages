import AppKit
import SwiftUI
import QuickLook

struct ArchiveRootView: View {
    @EnvironmentObject private var model: ArchiveModel
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationSplitView {
            ArchiveSidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.error, model.overview != nil { ErrorBanner(text: error) }
                if model.overview == nil {
                    ArchiveWelcome().navigationTitle("Local Messages")
                } else if let conversation = model.selectedConversation {
                    ConversationDetail(conversation: conversation)
                } else {
                    ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right", description: Text("Choose a conversation from the sidebar."))
                        .navigationTitle("Local Messages")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(archiveAccent)
        .frame(minWidth: 860, minHeight: 560)
        .background(WindowKeyObserver { key in
            model.windowIsKey = key
            if key { model.windowBecameKey() }
        })
        .quickLookPreview($model.previewURL)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $model.showingAccounts) { AccountsView(pairing: model.addingAccount).environmentObject(model) }
        .sheet(isPresented: $model.showingNewMessage) { NewMessageView().environmentObject(model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.notifications.refreshSettings() }
        }
    }
}

private struct ErrorBanner: View {
    @EnvironmentObject private var model: ArchiveModel
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            Button("Retry", action: model.reload).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.orange.opacity(0.10))
        Divider()
    }
}

private struct ArchiveWelcome: View {
    @EnvironmentObject private var model: ArchiveModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 52, weight: .light)).foregroundStyle(archiveAccent)
                .padding(.bottom, 6)
            Text(model.loading ? "Opening your archive…" : "Your messages, on your Mac")
                .font(.system(size: 24, weight: .semibold))
            Text(model.error ?? "Browse conversations, revisit photos and find what you need.\nEverything you open here is saved locally.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if model.loading { ProgressView().controlSize(.small).padding(.top, 6) }
            else {
                HStack(spacing: 12) {
                    Button("Open Saved Archive…", action: model.chooseArchive).controlSize(.large)
                    Button("Add Google Account…", action: model.prepareNewAccount).buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(.top, 8)
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
