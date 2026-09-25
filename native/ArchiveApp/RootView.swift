import AppKit
import SwiftUI
import QuickLook

struct ArchiveRootView: View {
    @Environment(ArchiveModel.self) private var model
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        @Bindable var bindable = model
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
            .background(SidebarSlideFix())
        }
        .navigationSplitViewStyle(.balanced)
        .tint(archiveAccent)
        .frame(minWidth: 860, minHeight: 560)
        .background(WindowKeyObserver { key in
            model.windowIsKey = key
            if key { model.windowBecameKey() }
        })
        .quickLookPreview($bindable.previewURL)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $bindable.showingAccounts) { AccountsView(pairing: model.addingAccount).environment(model) }
        .sheet(isPresented: $bindable.showingNewMessage) { NewMessageView().environment(model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.notifications.refreshSettings() }
            model.sendPresence()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.sendPresence()
        }
    }
}

// AppKit's default sidebar expansion holds the detail pane at its width while
// the sidebar grows, and SwiftUI accommodates that by laying the split view out
// wider than the window, centred: sidebar and conversation slid left at half the
// sidebar's speed, then jumped the rest when the animation ended. Constraint-
// driven expansion keeps the split view at the window's width and shrinks the
// detail pane frame by frame. The mode is chosen from the collapsed state once
// the sidebar's wrapper has finished moving, so a running slide is never changed.
private struct SidebarSlideFix: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.attach() }
    final class Probe: NSView {
        private weak var sidebar: NSSplitViewItem?
        private weak var splitView: NSSplitView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        deinit { NotificationCenter.default.removeObserver(self) }
        func attach() {
            guard sidebar == nil else { return }
            var view: NSView? = self
            while let current = view, !(current is NSSplitView) { view = current.superview }
            guard let splitView = view as? NSSplitView, let controller = splitView.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first, item.canCollapse else { return }
            sidebar = item
            self.splitView = splitView
            // Posted on the main thread for every resize, including each collapse or expansion.
            NotificationCenter.default.addObserver(self, selector: #selector(sidebarChanged), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
            sidebarChanged()
        }
        @objc private func sidebarChanged() {
            guard let sidebar, let splitView, let wrapper = splitView.arrangedSubviews.first else { return }
            let wanted: NSSplitViewItem.CollapseBehavior
            if !sidebar.isCollapsed { wanted = .default }
            else if wrapper.frame.width < 0.5 || splitView.isSubviewCollapsed(wrapper) { wanted = .useConstraints }
            else { return } // still closing
            if sidebar.collapseBehavior != wanted { sidebar.collapseBehavior = wanted }
        }
    }
}

private struct ErrorBanner: View {
    @Environment(ArchiveModel.self) private var model
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
    @Environment(ArchiveModel.self) private var model
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
                    Button("Add Google Account…", action: model.prepareNewAccount).prominentButton().controlSize(.large)
                }.padding(.top, 8)
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
