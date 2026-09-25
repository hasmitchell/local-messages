import AppKit
import SwiftUI

@MainActor
final class ArchiveAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ArchiveModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.finishDraftSaves()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LocalMessagesApp: App {
    @NSApplicationDelegateAdaptor(ArchiveAppDelegate.self) private var delegate
    @State private var model = ArchiveModel()
    var body: some Scene {
        Window("Local Messages", id: "archive") {
            ArchiveRootView().environment(model).task {
                delegate.model = model
                model.start()
                #if UI_SNAPSHOTS
                SnapshotRunner.schedule(model: model)
                #endif
            }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message…") { model.startError = nil; model.showingNewMessage = true }
                    .keyboardShortcut("n").disabled(!model.canSync || model.loading)
                Button("Open Archive…", action: model.chooseArchive).keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Conversation") { model.showingThreadSearch = true }
                    .keyboardShortcut("f").disabled(model.selectedID == nil)
                Button("Search All Messages") { model.focusSearch = UUID() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Conversation") {
                Button(model.showingDetails ? "Hide Conversation Info" : "Show Conversation Info", action: model.toggleDetails)
                    .keyboardShortcut("i").disabled(model.selectedID == nil)
                Button("Jump to Latest Message", action: model.showLatest).keyboardShortcut("j").disabled(model.selectedID == nil)
                Divider()
                Button("Reload Archive", action: model.reload).keyboardShortcut("r").disabled(model.loading)
            }
        }
        Settings { AppSettingsView().environment(model) }
    }
}
