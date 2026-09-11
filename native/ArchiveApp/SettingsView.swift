import AppKit
import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var model: ArchiveModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            NotificationSettingsPane(controller: model.notifications).tabItem { Label("Notifications", systemImage: "bell.badge") }.tag("notifications")
            ConnectionSettings().tabItem { Label("Connection", systemImage: "iphone.gen3.radiowaves.left.and.right") }.tag("connection")
            HistorySettings().tabItem { Label("History & Storage", systemImage: "externaldrive") }.tag("history")
        }
        .frame(width: 560)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("dockBadge") private var dockBadge = true
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Follow macOS").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }
            Section("Unread messages") {
                Toggle("Show unread count on the app icon", isOn: $dockBadge)
                Text("A conversation counts as unread until you open it here or read it on your phone. Reading on this Mac never changes the phone's read status.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(height: 270)
    }
}

private struct NotificationSettingsPane: View {
    @ObservedObject var controller: MessageNotifications
    var body: some View {
        Form {
            Section("Desktop notifications") {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(controller.status)
                        if controller.permissionBlocked { Button("Open macOS Settings…", action: controller.openSettings).controlSize(.small) }
                        else { Button(controller.enabled ? "Turn Off" : "Turn On", action: controller.toggle).controlSize(.small) }
                    }
                }
                Toggle("Show message previews", isOn: Binding(get: { controller.previews }, set: { _ in controller.togglePreviews() }))
                Toggle("Notify while viewing the conversation", isOn: Binding(get: { controller.notifyWhileReading }, set: { controller.setNotifyWhileReading($0) }))
                Text("Alerts require the app to be open and syncing. macOS can silence them during Focus or screen sharing. Previews are hidden by default so banners only say a message arrived.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Test") {
                    Button("Send Test Notification", action: controller.test).controlSize(.small).disabled(!controller.enabled || controller.permissionBlocked)
                }
                if let result = controller.testResult { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).frame(height: 330)
    }
}

private struct ConnectionSettings: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var showingReconnect = false
    private var statusColor: Color {
        switch model.syncState {
        case .connected, .photosPending: .green
        case .pairingRequired, .unavailable, .keychainError, .stopped: .red
        case .paused, .sleeping, .local: Color.secondary
        default: .orange
        }
    }
    var body: some View {
        Form {
            Section("Phone connection") {
                LabeledContent("Account") { Text(model.accountName) }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.canSync ? statusColor : Color.secondary).frame(width: 7, height: 7)
                        Text(model.canSync ? model.syncState.label : "Local archive · read-only")
                    }
                }
                if model.canSync {
                    Toggle("Sync while Local Messages is open", isOn: Binding(get: { model.syncEnabled }, set: { _ in model.toggleSync() })).disabled(model.pairingBusy)
                    LabeledContent("Pairing") {
                        Button("Reconnect Account…") { model.relinking.reset(); showingReconnect = true }.controlSize(.small).disabled(model.savingSettings || model.pairingBusy)
                    }
                    Text("If the pairing expires or Google signs out, reconnect with the original account and phone to keep using this archive. Saved messages, attachments and drafts are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This archive was imported without a phone pairing. Add a Google account to receive and send messages.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Accounts") {
                LabeledContent("Saved accounts") {
                    HStack {
                        Text(model.accounts.count == 1 ? "1 account" : "\(model.accounts.count) accounts").foregroundStyle(.secondary)
                        Button("Manage Accounts…") {
                            model.showingAccountSetup = false
                            model.showingAccounts = true
                            (NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("archive") == true } ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
                        }.controlSize(.small).disabled(model.pairingBusy)
                    }
                }
                Text("Only the selected account syncs and shows notifications. Each account keeps a separate archive on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(height: 360)
        .sheet(isPresented: $showingReconnect) { RelinkView(controller: model.relinking).environmentObject(model) }
    }
}

private struct HistorySettings: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var draft = ArchiveSettings.initial
    @State private var cleanupCount: Int?
    private var cleanupEnabled: Binding<Bool> { Binding(get: { draft.retentionDays > 0 }, set: { draft.retentionDays = $0 ? 365 : 0 }) }
    private var changed: Bool { draft != model.settings }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Message history") {
                    DatePicker("Retrieve messages from", selection: Binding(get: { draft.date }, set: { draft.historySince = ArchiveSettings.dateString($0) }), in: ArchiveSettings.parseDate("2000-01-01")!...Date(), displayedComponents: .date)
                    LabeledContent("Quick choices") {
                        HStack(spacing: 6) {
                            Button("Past year") { draft.historySince = ArchiveSettings.initial.historySince }
                            Button("Past 5 years") { draft.historySince = ArchiveSettings.dateString(Calendar.current.date(byAdding: .year, value: -5, to: Date())!) }
                            Button("All available") { draft.historySince = "2000-01-01" }
                        }.controlSize(.small)
                    }
                    Text("Earlier dates retrieve older history and supported attachments from your phone. Large imports take time, and coverage depends on what Google Messages returns. Moving this date later does not delete saved messages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Local storage") {
                    ArchiveStorageView(directory: model.directory).id(model.directory)
                    Toggle("Automatically remove older local copies", isOn: cleanupEnabled)
                    if draft.retentionDays > 0 {
                        Picker("Keep on this Mac", selection: $draft.retentionDays) {
                            Text("30 days").tag(30); Text("90 days").tag(90); Text("6 months").tag(180); Text("1 year").tag(365); Text("2 years").tag(730)
                        }
                        Text("Removes older saved messages and their downloaded attachments from this Mac when sync runs. Messages on your phone stay unchanged. Unconfirmed sends and drafts are kept.").font(.caption).foregroundStyle(.secondary)
                        if let cleanupCount { Text("Approximately \(cleanupCount.formatted()) saved messages are older than this window.").font(.caption).foregroundStyle(.orange) }
                        Text("Only history inside this window is downloaded while cleanup is on. Turn it off and choose an earlier date to retrieve older messages again.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Off. Everything already saved on this Mac is kept.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Group {
                    if let error = model.settingsError { Text(error).foregroundStyle(.red) }
                    else if let notice = model.settingsNotice { Text(notice).foregroundStyle(.secondary) }
                    else if changed { Text("Changes apply to the open archive when you click Apply.").foregroundStyle(.secondary) }
                    else { Text("History and cleanup settings for “\(model.accountName)”.").foregroundStyle(.secondary) }
                }.font(.caption).lineLimit(2)
                Spacer()
                Button(model.savingSettings ? "Applying…" : "Apply") { model.saveSettings(draft) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!draft.valid || model.savingSettings || model.directory == nil || !changed)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(height: 620)
        .onAppear { draft = model.settings; model.settingsNotice = nil; model.settingsError = nil }
        .onChange(of: model.directory) { draft = model.settings; cleanupCount = nil }
        .onChange(of: model.settings) { draft = model.settings }
        .task(id: draft) { cleanupCount = await model.cleanupPreview(draft) }
    }
}

private struct ArchiveStorageView: View {
    let directory: URL?
    @State private var reader = ArchiveStorageReader()
    @State private var usage: ArchiveStorageUsage?
    @State private var storageError: String?
    @State private var calculating = false
    @State private var refresh = UUID()
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        LabeledContent("Archive size") {
            HStack(spacing: 8) {
                if let usage { Text(size(usage.total)).fontWeight(.semibold).monospacedDigit().accessibilityIdentifier("archiveStorageTotal") }
                else { Text(directory == nil ? "No archive open" : "Calculating…").foregroundStyle(.secondary) }
                if calculating { ProgressView().controlSize(.mini).accessibilityLabel("Calculating archive size") }
                else {
                    Button { refresh = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(directory == nil)
                        .help("Refresh archive size").accessibilityLabel("Refresh archive size")
                }
            }
        }
        if let usage {
            if let free = usage.availableOnDrive { LabeledContent("Available on this drive") { Text(size(free)).monospacedDigit() } }
            DisclosureGroup("Storage breakdown") {
                VStack(spacing: 6) {
                    storageRow("Message database", usage.database)
                    storageRow("Photos and downloaded files", usage.media)
                    storageRow("Drafts and staged attachments", usage.drafts)
                    storageRow("Database working files", usage.workingFiles)
                    storageRow("Settings and other files", usage.other)
                }.font(.caption).padding(.top, 4)
            }
            Text(usage.incomplete ? "Some files could not be measured; this total may be incomplete." : "Approximate space used on disk for this archive. Imports can increase it.")
                .font(.caption).foregroundStyle(usage.incomplete ? .orange : .secondary)
        }
        if let storageError { Text(storageError).font(.caption).foregroundStyle(.secondary) }
        Color.clear.frame(height: 0)
            .task(id: refresh) {
                guard let directory else { return }
                while !Task.isCancelled {
                    calculating = true
                    do {
                        let measured = try await reader.measure(directory: directory)
                        try Task.checkCancellation()
                        usage = measured
                        storageError = nil
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled else { return }
                        storageError = "The current archive size could not be measured. Try refreshing."
                    }
                    calculating = false
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                }
            }
    }
    private func storageRow(_ title: String, _ bytes: Int64) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(size(bytes)).monospacedDigit() }
    }
}
